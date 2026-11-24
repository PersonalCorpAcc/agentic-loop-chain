#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/restart-orphans.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Start implement or refine work that nothing else will ever start (FR-132; FR-140 for refine).
# The reconcile belt runs this after retry-pending, on every pass, once per route: ROUTE is
# `implement` (the default) or `refine`, and ROUTE_LABEL is that route's label.
#
# Every other restart in the loop hangs off something finishing: a worker's last step re-
# dispatches, a marked comment asks the belt for a retry, a blocker closing releases a held
# issue. When the thing that should have finished never ran -- GitHub dropped the label event,
# the re-dispatch at the end of a failed run was lost, a run was cancelled -- the issue keeps its
# route label with no run, no pull request and no marker, and sits there for ever (loopscope
# #304, labelled 22/11/2026 10:35 and never started; #248, "this is being retried" on 21/11 and
# never retried). This looks at state, not at events: an open issue that asks for the route and
# that nothing holds is started again.
#
# An issue is an orphan when, and only when:
#   - it is open and carries the route's label, and none of the working, review, hold or
#     pending-pull-request labels (a run holds it, a person has it, a person stopped it, or its pull
#     request is open). Refine asks a person with `review`, so a question is never an orphan;
#   - nothing has touched it for ORPHAN_AFTER_MINUTES, so a label event still on its way wins;
#   - whoever last added the route's label may start an agent here: the App, or a person with
#     write access. The restart is dispatched by the App, which the router trusts, so this is
#     the router's authorisation asked again; without it a label the router refused would start
#     work half an hour later (FR-133);
#   - implement only: no pull request from this loop is open or merged on one of its
#     `agent/<issue>-` branches. Implement releases its working label before it adds the pending one,
#     so a run that failed in between leaves an issue that looks unheld while its pull request
#     is open (FR-133);
#   - implement only: none of its `Blocked by #M` blockers is open; the held-for-blockers sweep
#     owns those;
#   - its newest comment is not a retry-pending marker, which retry-pending owns;
#   - no router run for it is queued or running.
# Each restart leaves a marked comment, which is also what spaces restarts out: the comment
# touches the issue, so the next one waits another window. After RETRY_ATTEMPTS restarts in a
# row with nothing else said, the issue goes to a person instead. One issue's failed lookup is a
# warning, never the end of the pass.
#
# Reads: REPO, GH_TOKEN, DEFAULT_BRANCH, ROUTE, ROUTE_LABEL (else IMPLEMENT_LABEL), WORKING_LABEL,
#        REVIEW_LABEL, HOLD_LABEL, PR_PENDING_LABEL, BOT_LOGIN, ORPHAN_AFTER_MINUTES,
#        RETRY_ATTEMPTS; NOW for tests.
set -euo pipefail

now="${NOW:-$(date -u +%s)}"
after="${ORPHAN_AFTER_MINUTES:-30}"
route="${ROUTE:-implement}"
label="${ROUTE_LABEL:-${IMPLEMENT_LABEL:-implement}}"
marker="<!-- agent-orphan-restart: ${route} -->"
Route="$(tr '[:lower:]' '[:upper:]' <<<"${route:0:1}")${route:1}"

# The same pre-filter as retry-pending's (decision D4): the worker's own eligibility check and
# concurrency group make a duplicate harmless; this only avoids starting one.
run_in_flight() {
  local issue="$1" status live
  for status in queued in_progress waiting pending requested; do
    live=$(gh api "repos/$REPO/actions/workflows/work-router.yml/runs?status=$status&per_page=100" \
      --jq "[.workflow_runs[] | select((.display_title | endswith(\"(#${issue})\")) or (.display_title | endswith(\": #${issue}\")))] | length" 2>/dev/null || echo 1)
    [ "${live:-1}" -eq 0 ] || return 0
  done
  return 1
}

# The router's own rule (authorize-actor.sh): the App, the workflow token, or write access.
# Anything unreadable is untrusted: the cost is a person re-adding the label.
labeller_trusted() {
  local issue="$1" actor permission
  actor="$(gh api "repos/$REPO/issues/$issue/events?per_page=100" --paginate \
    --jq ".[] | select(.event == \"labeled\" and .label.name == \"${label}\") | .actor.login" 2>/dev/null | tail -n 1 || true)"
  [ -n "$actor" ] || return 1
  if [ "$actor" = "github-actions[bot]" ] || [ "$actor" = "${BOT_LOGIN:-}" ]; then
    return 0
  fi
  permission="$(gh api "repos/$REPO/collaborators/$actor/permission" --jq '.permission' 2>/dev/null || echo none)"
  case "$permission" in admin | maintain | write) return 0 ;; esac
  echo "#$issue: ${label} was added by $actor ($permission), who may not start an agent here; leaving it."
  return 1
}

open_blockers() {
  local body="$1" blocker state still=""
  for blocker in $(grep -oiE 'blocked by #[0-9]+' <<<"$body" | grep -oE '[0-9]+' | sort -un || true); do
    state="$(gh issue view "$blocker" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    [ "$state" = "CLOSED" ] || still="${still} #${blocker}"
  done
  printf '%s' "${still# }"
}

# Head branches of this loop's pull requests that are open or merged, read once per pass.
changes=""
if [ "$route" = implement ]; then
  changes="$(gh api "repos/$REPO/pulls?state=all&per_page=100" --paginate \
    --jq '.[] | select(.state == "open" or .merged_at != null) | .head.ref' 2>/dev/null || true)"
fi

issues="$(gh issue list --repo "$REPO" --label "$label" --state open --limit 100 --json number,labels,updatedAt,body \
  --jq ".[] | select([.labels[].name] | (index(\"${WORKING_LABEL}\") or index(\"${REVIEW_LABEL}\") or index(\"${HOLD_LABEL}\") or index(\"${PR_PENDING_LABEL}\")) | not) | [.number, .updatedAt, (.body // \"\" | @json)] | @tsv")"

while IFS=$'\t' read -r issue updated body_json; do
  case "$issue" in '' | *[!0-9]*) continue ;; esac
  [ -n "${updated:-}" ] || continue

  idle=$(( (now - $(date -u -d "$updated" +%s)) / 60 ))
  if [ "$idle" -lt "$after" ]; then
    echo "#$issue: asks for ${route} with nothing holding it, idle ${idle}m of ${after}m."
    continue
  fi

  if [ "$route" = implement ]; then
    if grep -qE "^agent/${issue}-" <<<"$changes"; then
      echo "#$issue: a pull request from this loop is open or merged on one of its branches; not starting another."
      continue
    fi
    blocked="$(open_blockers "$(jq -r '.' <<<"${body_json:-\"\"}" 2>/dev/null || true)")"
    if [ -n "$blocked" ]; then
      echo "#$issue: still blocked by ${blocked}; the held-for-blockers sweep starts it."
      continue
    fi
  fi

  # Comments come oldest first, page by page, so the last body is the newest.
  bodies="$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --paginate --jq '.[] | .body | @json' 2>/dev/null || true)"
  newest="$(tail -n 1 <<<"$bodies")"
  case "$newest" in *"agent-retry-pending: "*) continue ;; esac

  labeller_trusted "$issue" || continue

  # Restarts in a row: markers since the last comment that is not one.
  restarts="$(tac <<<"$bodies" | awk -v m="agent-orphan-restart: ${route}" 'index($0, m) { n++; next } NF { exit } END { print n + 0 }')"
  if [ "${restarts:-0}" -ge "$RETRY_ATTEMPTS" ]; then
    echo "#$issue: restarted ${restarts} times with nothing to show; handing it to a person."
    gh issue edit "$issue" --repo "$REPO" --add-label "$REVIEW_LABEL" >/dev/null 2>&1 || true
    gh issue comment "$issue" --repo "$REPO" --body "${Route} was started on this issue ${restarts} times after it was found with nothing working on it, and nothing came of any of them, so it is no longer restarted. The issue now carries \`${REVIEW_LABEL}\`; remove it and re-add \`${label}\` to try again." >/dev/null 2>&1 || true
    continue
  fi
  if run_in_flight "$issue"; then
    echo "#$issue: a run for it is already in flight."
    continue
  fi

  # Refine runs a second pass once it has already spoken on the issue (its own marker).
  mode=()
  if [ "$route" = refine ]; then
    case "$bodies" in *"<!-- agent-refine -->"*) mode=(-f "inputs[mode]=rerefine") ;; *) mode=(-f "inputs[mode]=first") ;; esac
  fi

  echo "#$issue: asks for ${route}, idle ${idle}m with nothing working on it and no marker; starting it."
  if gh api "repos/$REPO/actions/workflows/work-router.yml/dispatches" --method POST \
    -f ref="$DEFAULT_BRANCH" -f "inputs[operation]=${route}" -f "inputs[issue-number]=${issue}" "${mode[@]}" >/dev/null; then
    gh issue comment "$issue" --repo "$REPO" --body "${marker}
This issue asked for ${route} and nothing was working on it: no run, and nothing scheduled to start one for ${idle} minutes. ${Route} has been started again." >/dev/null 2>&1 || true
  else
    echo "::warning::Could not start ${route} on #${issue}; the next sweep will try again."
  fi
done <<<"$issues"
