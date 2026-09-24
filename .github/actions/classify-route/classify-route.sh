#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/classify-route/classify-route.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
# Classify one GitHub event into exactly one route. Pure: no network, no gh calls, so
# verify-route-matrix.sh can source this file and exercise the same code the router runs.
#
# Reads the event facts from the environment and writes `key=value` lines to stdout.
# The caller appends them to $GITHUB_OUTPUT.

set -euo pipefail

# has_label shells out to jq with its errors discarded, because a label that is
# absent is the ordinary case and must be quiet. That made a missing jq binary
# indistinguishable from "no labels": every check read as absent, an issue
# opened with a work label was routed to triage, and a comment on a refine issue
# went nowhere, all without a word. On a runner that is a silent mis-route of
# every event. Fail once, here, and say what is missing.
if ! command -v jq >/dev/null 2>&1; then
  echo "classify-route: jq is not on PATH. Every label check would silently read as absent, so nothing is classified." >&2
  exit 1
fi

# The branching strategy, as constants rather than as a profile this reads at run time:
# nothing in an installed repository reads a profile, and this file is sourced by the route
# matrix, which has no other way to know which strategy it is checking (Principle II,
# FR-042, FR-051).
# BRANCH_STRATEGY and CUT_FROM are read by verify-route-matrix.sh, which sources this file
# to exercise the real classifier rather than restating it, so shellcheck cannot see their
# use from here.
# shellcheck disable=SC2034
readonly BRANCH_STRATEGY="branch-chain"
# The stages a change is promoted through, in order. One entry under a strategy with no
# chain: the branch every change is cut from and merged back into.
readonly STAGE_BRANCHES=("dev" "test" "main")
# shellcheck disable=SC2034
readonly CUT_FROM="dev"
readonly CLOSE_ISSUE_ON="main"

# Each clock is optional, because a profile may set any of them to `off` and the line then
# disappears along with the router's schedule entry (FR-081). Every reader below asks whether
# the constant exists before comparing, so a silenced route is one nothing can reach by a
# schedule rather than one that fires at a minute this file does not recognise.
readonly RECONCILE_BOT_PR_RUNS_CRON="23 * * * *"
# The fifth clock, and the only one a profile can switch off: a trunk repository has no
# later stage to promote into, so the projector writes no value and this line disappears
# with it (FR-031).
readonly PROMOTE_CRON="41 * * * *"
# The sixth, and switched off by the same fact: a repository with one branch has no stage
# that can fall behind another, so there is nothing to carry back down (FR-079).

has_label() {
  jq -e --arg name "$1" 'index($name)' >/dev/null 2>&1 <<<"${ISSUE_LABELS:-[]}"
}

# Is this branch one of the strategy's stages? A merge into one is a transition in the
# change's life; a merge into anybody's own branch is not this loop's business.
is_stage_branch() {
  local candidate="$1" stage
  [ -n "$candidate" ] || return 1
  for stage in "${STAGE_BRANCHES[@]}"; do
    if [ "$stage" = "$candidate" ]; then
      return 0
    fi
  done
  # A release branch is a stage too, for the strategy that cuts them: a hotfix merged into
  # one is a transition, and the release pattern is how they are recognised (FR-055). The
  # constant is absent entirely for a strategy that cuts none -- the optional token removes
  # its own line -- so it is read defensively rather than assumed.
  if [ -n "${RELEASE_PATTERN:-}" ] && printf '%s' "$candidate" | grep -qE "${RELEASE_PATTERN}"; then
    return 0
  fi
  return 1
}

is_issue_number() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

classify_route() {
  local route="none" error=""
  local issue_number="" pr_number="" ci_conclusion="" ci_run_id="" merge_gate_attempts="0" implement_attempts="0"
  local refine_mode="" triage_mode="" trigger_kind=""
  local pr_merged="" closes_issue="false" pr_base=""

  case "${EVENT:-}" in
    issues)
      # A closed issue is finished work, but label edits on one still arrive as events.
      if [ "${ISSUE_STATE:-}" = "closed" ]; then
        error="issue is closed"
      elif [ "${ACTION:-}" = "opened" ]; then
        # Issue opened with a work label → skip triage.
        # The label event will trigger authorize-bot-work → bot-working → the
        # correct worker. Triage would only interfere.
        if has_label refine || has_label implement; then
          error="issue opened with a work label; triage skipped"
        else
          # Issue opened by an outside collaborator → triage. The authorize job
          # gates the caller on is_outside_collaborator; this routes unconditionally
          # so write+ openers classify to triage but the caller job skips them.
          route="triage"
          triage_mode="first"
          issue_number="${EVENT_ISSUE_NUMBER:-}"
        fi
      elif [ "${ACTION:-}" = "labeled" ]; then
        case "${LABEL:-}" in
          bot-working)
            # Bot adds bot-working → route based on which work label is present
            # BUT: if review label is present, do NOT route (human review required)
            if has_label review; then
              error="issue has review label; bot-working does not re-trigger while human review is required"
            elif has_label implement; then
              route="implement"
              issue_number="${EVENT_ISSUE_NUMBER:-}"
            elif has_label refine; then
              route="refine"
              refine_mode="first"
              issue_number="${EVENT_ISSUE_NUMBER:-}"
            else
              error="bot-working added but no work label found"
            fi
            ;;
          triage)
            # A maintainer can explicitly re-run triage by adding this label. The
            # triage worker adds it after claiming the issue, so bot label events
            # and an existing claim must not start a second worker.
            if [ "${ACTOR:-}" != "" ] && echo "${ACTOR:-}" | grep -q '\[bot\]$'; then
              error="bot-added triage label does not re-trigger triage"
            elif has_label bot-working; then
              error="issue already has bot-working label; triage already in progress"
            else
              route="triage"
              issue_number="${EVENT_ISSUE_NUMBER:-}"
              triage_mode="first"
            fi
            ;;
          refine | implement)
            # If the actor is a bot (e.g. refine→implement transition), route directly.
            # If the actor is a human, authorize-bot-work.yml will add bot-working which triggers the workflow.
            if [ "${ACTOR:-}" != "" ] && echo "${ACTOR:-}" | grep -q '\[bot\]$'; then
              route="${LABEL:-}"
              issue_number="${EVENT_ISSUE_NUMBER:-}"
              if [ "${LABEL:-}" = "refine" ]; then
                refine_mode="first"
              fi
            elif has_label bot-working; then
              # Already has bot-working - the workflow is already running or queued.
              # Don't re-trigger.
              error="issue already has bot-working label; implement/refine already in progress"
            else
              error="waiting for bot to add bot-working label"
            fi
            ;;
        esac
      fi
      ;;

    issue_comment)
      if [ "${COMMENT_ON_PR:-false}" = "true" ]; then
        if [ "${COMMENT_SENDER_TYPE:-}" = "Bot" ]; then
          # Every App-token comment on a pull request is an issue_comment event, and the
          # workers comment on pull requests they own. None of that is reviewer feedback.
          error="comment authored by a bot"
        else
          route="apply-review"
          pr_number="${EVENT_ISSUE_NUMBER:-}"
        fi
      elif [ "${ISSUE_STATE:-}" = "closed" ]; then
        # A closing comment on a refine-labelled issue used to start a full re-refine, which
        # held a runner for 35 minutes and filed split children under an already-shut parent.
        error="issue is closed"
      elif [ "${COMMENT_SENDER_TYPE:-}" = "Bot" ]; then
        error="comment authored by a bot"
      elif has_label triage; then
        route="triage"
        triage_mode="retriage"
        issue_number="${EVENT_ISSUE_NUMBER:-}"
      elif has_label implement; then
        error="issue has implement label; comments do not re-trigger implement"
      elif ! has_label refine; then
        error="issue does not carry the refine label"
      else
        route="refine"
        refine_mode="rerefine"
        issue_number="${EVENT_ISSUE_NUMBER:-}"
      fi
      ;;

    pull_request_review_comment | pull_request_review)
      route="apply-review"
      pr_number="${EVENT_PR_NUMBER:-}"
      ;;

    pull_request_target)
      # A pull request closing on a stage is the moment a change moves, and it is the only
      # moment the loop can see: merged or not, by the bot or by a person. It belongs to
      # stage-merge rather than to the approval route, which exists to approve queued runs
      # on an opening pull request (FR-051).
      if [ "${ACTION:-}" = "closed" ] && is_stage_branch "${PR_BASE_REF:-}"; then
        route="stage-merge"
        pr_number="${EVENT_PR_NUMBER:-}"
        pr_merged="${PR_MERGED:-false}"
        pr_base="${PR_BASE_REF:-}"
        # Whether this merge ends the change's life. Decided here, once, in the one place
        # that is a pure function of the event and the profile: the router job then acts on
        # an answer rather than on a comparison it would have to repeat (FR-030).
        if [ "$pr_merged" = "true" ] && [ "${PR_BASE_REF:-}" = "$CLOSE_ISSUE_ON" ]; then
          closes_issue="true"
        else
          closes_issue="false"
        fi
      elif [ "${ACTION:-}" = "labeled" ] && [ "${LABEL:-}" = "merge-gate" ]; then
        # Human adds merge-gate label to bot PR → triggers merge-gate with human actor
        # This bypasses gh-aw's bot membership check since the actor is human
        route="merge-gate"
        pr_number="${EVENT_PR_NUMBER:-}"
        # CI status will be fetched by the merge-gate workflow
        ci_conclusion=""
        ci_run_id=""
      else
        route="bot-approve"
      fi
      ;;

    workflow_run)
      # Only a FAILED CI run on an attached pull request auto-dispatches the gate. A green
      # run reaches the gate through the consumer CI's dispatch-merge-gate job and the
      # reconcile belt, so routing success here would double-fire the gate for every passing
      # pull request. GitHub delivers workflow_run only for CI runs whose actor is a human;
      # a bot pull request's CI never arrives here at all, and the same two paths cover it.
      if [ "${RUN_CONCLUSION:-}" != "failure" ]; then
        error="CI concluded '${RUN_CONCLUSION:-}'; the gate auto-triggers only on failure"
      elif is_issue_number "${RUN_PR_NUMBER:-}"; then
        route="merge-gate"
        pr_number="${RUN_PR_NUMBER}"
        ci_conclusion="failure"
        ci_run_id="${RUN_ID:-}"
      else
        error="CI run has no attached pull request"
      fi
      ;;

    schedule)
      trigger_kind="scheduled"
      # One shape for all six, because any of them may be absent: a `case` on a constant that
      # does not exist matches the empty string, so a silenced clock would answer for a
      # schedule with no value at all. Each is compared only when it has one.
      if [ -n "${AUDIT_CRON:-}" ] && [ "${SCHEDULE:-}" = "$AUDIT_CRON" ]; then
        route="audit"
      elif [ -n "${AUDIT_CLOSE_CRON:-}" ] && [ "${SCHEDULE:-}" = "$AUDIT_CLOSE_CRON" ]; then
        route="audit-close"
      elif [ -n "${CLEANUP_ARTIFACTS_CRON:-}" ] && [ "${SCHEDULE:-}" = "$CLEANUP_ARTIFACTS_CRON" ]; then
        route="cleanup-artifacts"
      elif [ -n "${RECONCILE_BOT_PR_RUNS_CRON:-}" ] && [ "${SCHEDULE:-}" = "$RECONCILE_BOT_PR_RUNS_CRON" ]; then
        route="reconcile-bot-pr-runs"
      elif [ -n "${PROMOTE_CRON:-}" ] && [ "${SCHEDULE:-}" = "$PROMOTE_CRON" ]; then
        route="promote"
      elif [ -n "${SYNC_STAGES_CRON:-}" ] && [ "${SCHEDULE:-}" = "$SYNC_STAGES_CRON" ]; then
        route="sync-stages"
      else
        error="no route for cron '${SCHEDULE:-}'"
      fi
      ;;

    workflow_dispatch)
      trigger_kind="manual"
      case "${OPERATION:-}" in
        refine | implement)
          if is_issue_number "${INPUT_ISSUE_NUMBER:-}"; then
            route="${OPERATION}"
            issue_number="${INPUT_ISSUE_NUMBER}"
            if [ "$OPERATION" = "refine" ]; then
              refine_mode="${INPUT_MODE:-first}"
            else
              # The implement worker re-dispatches itself when a run dies before doing any work,
              # and carries the count so the budget is bounded.
              implement_attempts="${INPUT_ATTEMPTS_SO_FAR:-0}"
            fi
          else
            error="operation '${OPERATION}' needs a positive issue-number, got '${INPUT_ISSUE_NUMBER:-}'"
          fi
          ;;
        triage)
          if is_issue_number "${INPUT_ISSUE_NUMBER:-}"; then
            route="triage"
            issue_number="${INPUT_ISSUE_NUMBER}"
            triage_mode="${INPUT_MODE:-first}"
          else
            error="operation 'triage' needs a positive issue-number, got '${INPUT_ISSUE_NUMBER:-}'"
          fi
          ;;
        apply-review)
          if is_issue_number "${INPUT_PR_NUMBER:-}"; then
            route="apply-review"
            pr_number="${INPUT_PR_NUMBER}"
          else
            error="operation 'apply-review' needs a positive pr-number, got '${INPUT_PR_NUMBER:-}'"
          fi
          ;;
        merge-gate)
          if is_issue_number "${INPUT_PR_NUMBER:-}"; then
            route="merge-gate"
            pr_number="${INPUT_PR_NUMBER}"
            ci_conclusion="${INPUT_CI_CONCLUSION:-}"
            ci_run_id="${INPUT_CI_RUN_ID:-}"
            merge_gate_attempts="${INPUT_ATTEMPTS_SO_FAR:-0}"
          else
            error="operation 'merge-gate' needs a positive pr-number, got '${INPUT_PR_NUMBER:-}'"
          fi
          ;;
        audit)
          route="${OPERATION}"
          trigger_kind="${INPUT_TRIGGER_KIND:-manual}"
          ;;
        audit-close | cleanup-artifacts | reconcile-bot-pr-runs | validate)
          route="${OPERATION}"
          ;;
        promote)
          # A strategy with one stage has nowhere to promote a change to. The job stays in
          # the router -- projection removes lines, not jobs -- so this is what makes it
          # unreachable, and it says why rather than running a route that would find
          # nothing every time (FR-031).
          #
          # Keyed on the strategy rather than on the stage count, unlike sync-stages below:
          # `release-branch` also has one stage and still reaches this route, because what
          # it promotes is not a change between stages but the release branch itself, cut
          # from the trunk on the cadence (FR-055).
          if [ "${BRANCH_STRATEGY}" = "trunk" ]; then
            error="this repository merges into one branch, so there is nowhere to promote to"
          else
            route="promote"
          fi
          ;;
        sync-stages)
          # The same fact from the other end: one branch cannot fall behind another, so
          # there is nothing to carry back down (FR-079).
          #
          # Two strategies answer here rather than one. `release-branch` also has a single
          # stage, and its release branches are *meant* to diverge from the trunk: carrying
          # the trunk back down onto them would undo every release they were cut to hold
          # (FR-055). So the test is the number of stages, which is the fact the rule is
          # actually about, rather than the name of one strategy that happens to have one.
          if [ "${#STAGE_BRANCHES[@]}" -lt 2 ]; then
            error="this repository merges into one branch, so no stage can fall behind another"
          else
            route="sync-stages"
          fi
          ;;
        release)
          route="release"
          ;;
        *)
          error="unknown operation '${OPERATION:-}'"
          ;;
      esac
      ;;

    *)
      error="unsupported event '${EVENT:-}'"
      ;;
  esac

  cat <<EOF
route=${route}
issue-number=${issue_number}
pr-number=${pr_number}
ci-conclusion=${ci_conclusion}
ci-run-id=${ci_run_id}
merge-gate-attempts=${merge_gate_attempts}
implement-attempts=${implement_attempts}
refine-mode=${refine_mode}
triage-mode=${triage_mode}
trigger-kind=${trigger_kind}
pr-merged=${pr_merged}
pr-base=${pr_base}
closes-issue=${closes_issue}
error=${error}
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  classify_route
fi
