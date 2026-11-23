#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate-sweep/merge-gate-sweep.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
# shellcheck shell=bash
#
# What the router's two merge-gate sweeps share (feature 007 WF-13, FR-036). The conflict
# sweep (after a merge) and the hourly reconcile belt each carried their own copy of these
# rules, about 150 lines apiece, and the copies had already drifted: one read mergeability
# through REST and the other through GraphQL, one counted any CI event and the other only
# pull_request, and the reconcile copy handed a no-CI pull request's issue to a person through
# a variable that was never set. One file, sourced by both, so a rule changes once.
#
# Sourced, not run. The caller sets:
#   REPO               owner/name
#   GH_TOKEN           a token that can read pull requests and dispatch workflows
#   DEFAULT_BRANCH     the ref the gate is dispatched at (FR-025)
#   CI_WORKFLOW_NAME   the CI workflow whose verdict the gate reads
#   MERGE_GATE_ATTEMPTS  failed gate attempts allowed on one CI verdict before parking
# and gets the functions below. Every lookup is through `gh`, so a test can stand in for it.

# pr_issues: every issue a pull request carries, one rule (FR-030, FR-056).
# shellcheck source=SCRIPTDIR/../resolve-pr-issue/resolve-pr-issue.sh
. "$(dirname "${BASH_SOURCE[0]}")/../resolve-pr-issue/resolve-pr-issue.sh"

# GitHub computes mergeability on demand. The first read of a pull request nobody has opened
# recently answers UNKNOWN while it works the answer out in the background, so reading once
# reports "not conflicting" for precisely the stale conflicting pull requests that need the
# gate. Ask until it settles. Prints MERGEABLE, CONFLICTING or UNKNOWN.
mergeable_state() {
  local pr="$1" state=UNKNOWN
  for _ in 1 2 3 4 5 6; do
    state=$(gh pr view "$pr" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null || echo UNKNOWN)
    [ "$state" = "UNKNOWN" ] || break
    sleep "${MERGEABLE_POLL_SECONDS:-5}"
  done
  echo "$state"
}

# A gate already queued or running for this pull request will read the same CI verdict; a
# second dispatch queues behind merge-belt and the single-slot queue cancels it.
#
# So this is a pre-filter (decision D4): `merge-belt-<base>` is what makes a duplicate gate
# harmless, and this only avoids starting one. It matches the exact title a *dispatch*
# renders, which is the only shape that carries a pull request number -- a gate a human
# starts with the `merge-gate` label, or one a failed CI run triggers, has a different run
# name and is invisible here. That is acceptable for a filter and would not be for a guard.
gate_is_live() {
  local pr="$1" status live
  for status in queued in_progress waiting pending; do
    live=$(gh api "repos/$REPO/actions/workflows/work-router.yml/runs?status=$status&per_page=100" \
      --jq "[.workflow_runs[] | select(.display_title == \"Working (Merge Gate): PR #${pr}\")] | length" 2>/dev/null || echo 0)
    [ "${live:-0}" -eq 0 ] || return 0
  done
  return 1
}

# The newest concluded (success or failure) pull_request run of the CI workflow matching a
# runs query (`head_sha=...` or `branch=...`), as `id<TAB>conclusion<TAB>updated_at`, or
# nothing. pull_request only: the gate judges the merge result, and a push run on the bot's
# branch judged something else.
ci_verdict() {
  gh api "repos/$REPO/actions/runs?$1&per_page=100" \
    --jq '[.workflow_runs[]
      | select(.name == env.CI_WORKFLOW_NAME and .event == "pull_request" and .status == "completed"
               and (.conclusion == "success" or .conclusion == "failure"))]
      | sort_by(.created_at) | last // empty | [.id, .conclusion, .updated_at] | @tsv'
}

# The CI verdict the gate should act on for one pull request, as ci_verdict prints it.
# Returns 1, printing nothing, when there is none yet and the pull request does not conflict:
# its own CI is still to come, and what to do about that is the caller's.
#
# A conflicting pull request has no merge ref for GitHub to build, so a `pull_request` CI
# workflow can never run on that head: refs/pull/N/merge is a 404 for as long as the conflict
# lasts. Waiting for a verdict that cannot arrive deadlocks the belt, because resolving the
# conflict is the gate's own job. So fall back to the branch's last verdict; the gate stays on
# the remediation path and cannot merge on a stale conclusion. With no verdict anywhere the
# gate goes in with none (`none`, `unknown`) to resolve the conflict, and the head commit's
# date stands in for the CI time, so a verdict already given on this head is not repeated
# (FR-108; loopscope #213, #214 and #231, 21/11/2026).
gate_ci() {
  local pr="$1" head_sha="$2" branch="$3" ci
  ci="$(ci_verdict "head_sha=$head_sha")"
  if [ -n "$ci" ]; then
    printf '%s\n' "$ci"
    return 0
  fi
  [ "$(mergeable_state "$pr")" = "CONFLICTING" ] || return 1
  ci="$(ci_verdict "branch=$branch")"
  if [ -n "$ci" ]; then
    echo "PR #$pr conflicts, so CI cannot run on $head_sha at all; gating on the branch's last verdict." >&2
    printf '%s\n' "$ci"
    return 0
  fi
  echo "PR #$pr conflicts and CI has never run on it; dispatching the gate to resolve the conflict." >&2
  gh api "repos/$REPO/commits/$head_sha" --jq '"none\tunknown\t" + .commit.committer.date'
}

# The newest terminal gate verdict on a pull request or any issue it carries, as a timestamp,
# or nothing. A verdict is a comment carrying BOTH the gate marker and a `**Verdict:**` line;
# progress comments and failed attempts carry neither pair, so a crashed gate never masks a
# pull request from later sweeps. Every carried issue, not the first: a promotion under
# `env-promotion` carries a set, and a verdict recorded on another of them would not be seen
# at all (FR-056).
latest_gate_verdict() {
  local pr="$1" subject
  {
    printf '%s\n' "$pr"
    pr_issues "$pr"
  } | while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    gh api "repos/$REPO/issues/$subject/comments?per_page=100" --paginate \
      --jq '.[] | select((.body | contains("<!-- agent-merge-gate -->")) and (.body | contains("**Verdict:**"))) | .created_at' 2>/dev/null || true
  done | sort | tail -n 1
}

# The word of the newest terminal gate verdict (`approve`, `merge`, `review`, `remediated`), over
# the same subjects as latest_gate_verdict, or nothing.
latest_gate_verdict_word() {
  local pr="$1" subject
  {
    printf '%s\n' "$pr"
    pr_issues "$pr"
  } | while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    # shellcheck disable=SC2016 # $v is jq's, not the shell's
    gh api "repos/$REPO/issues/$subject/comments?per_page=100" --paginate \
      --jq '.[] | select(.body | contains("<!-- agent-merge-gate -->")) | (.body | capture("\\*\\*Verdict:\\*\\* *(?<word>[a-z]+)")?) as $v | select($v != null) | [.created_at, $v.word] | @tsv' 2>/dev/null || true
  done | sort | tail -n 1 | cut -f2
}

# Whether the repository's auto-merge policy, as installed now, merges into this base unattended:
# the same rule as the gate's own policy step. AUTO_MERGE_MODE and AUTO_MERGE_TARGETS are the
# caller's, projected from the profile.
policy_merges_unattended() {
  local base="$1"
  [ "${AUTO_MERGE_MODE:-off}" != off ] && [ -n "$base" ] || return 1
  printf '%s\n' "${AUTO_MERGE_TARGETS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF -- "$base"
}

# Failed gate attempts (the attempt marker) since a CI verdict's time, on the pull request and
# every issue it carries: a budget counted against one of a promotion's issues is a fraction of
# the budget the gate is meant to have (FR-056).
gate_attempts_since() {
  local pr="$1" since="$2" subject
  {
    printf '%s\n' "$pr"
    pr_issues "$pr"
  } | while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    SINCE="$since" gh api "repos/$REPO/issues/$subject/comments?per_page=100" --paginate \
      --jq '.[] | select(.body | contains("<!-- agent-merge-gate-attempt -->")) | select(.created_at > env.SINCE) | .id' 2>/dev/null || true
  done | grep -c . || true
}

# Decide whether one pull request with a CI verdict gets a gate now, and dispatch it if so.
# Says what it decided either way, because a sweep's no-action case is per pull request.
dispatch_gate_if_due() {
  local pr="$1" ci_run_id="$2" ci_conclusion="$3" ci_finished="$4" verdict attempts
  [ "$ci_run_id" != none ] || ci_run_id=""

  # A recorded verdict counts only when it is NEWER than the CI verdict; the old existence
  # check made the gate one-shot per pull request.
  verdict="$(latest_gate_verdict "$pr")"
  if [ -n "$verdict" ] && [ "$verdict" \> "$ci_finished" ]; then
    # Except a clean assessment left to a person under a policy that has since changed: once
    # the base merges unattended, that pull request merges itself if the gate looks again, and
    # nothing else will make it look (FR-109; loopscope 20/11/2026, after autoMerge.targets
    # gained main, open promotions assessed before it waited for a person indefinitely).
    if [ "$(latest_gate_verdict_word "$pr")" = approve ] &&
      policy_merges_unattended "$(gh pr view "$pr" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"; then
      echo "PR #$pr: the gate approved it for a person to merge, and its base now merges unattended; re-assessing under the new policy."
    else
      echo "PR #$pr: the gate's verdict ($verdict) is newer than CI ($ci_finished); not dispatching."
      return 0
    fi
  fi
  attempts="$(gate_attempts_since "$pr" "$ci_finished")"
  if [ "${attempts:-0}" -ge "$MERGE_GATE_ATTEMPTS" ]; then
    echo "PR #$pr already consumed $attempts gate attempts on this CI verdict; parking for review."
    return 0
  fi
  if gate_is_live "$pr"; then
    echo "PR #$pr: a merge-gate run is already live; not dispatching another."
    return 0
  fi

  echo "Dispatching the merge gate for PR #$pr (CI $ci_conclusion, run ${ci_run_id:-none}, attempt $((attempts + 1)) of $MERGE_GATE_ATTEMPTS)."
  gh api "repos/$REPO/actions/workflows/work-router.yml/dispatches" \
    --method POST \
    -f ref="$DEFAULT_BRANCH" \
    -f "inputs[operation]=merge-gate" \
    -f "inputs[pr-number]=$pr" \
    -f "inputs[ci-conclusion]=$ci_conclusion" \
    -f "inputs[ci-run-id]=$ci_run_id" \
    -f "inputs[attempts_so_far]=$attempts"
}
