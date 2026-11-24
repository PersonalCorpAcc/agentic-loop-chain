#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/record-outcome/record-outcome.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# One line per job saying what happened and why (FR-058).
#
# Nothing used to write a step summary, and every no-work path exited 0, so a run that
# decided to do nothing looked exactly like a run that did something: all green, no answer.
# Reading the logs of eleven skipped jobs to find out whether the loop was working was the
# ordinary way to answer "did anything happen last night".
#
# The line is machine-readable first and human-readable second, because both questions get
# asked: a metrics collector wants `outcome=` and `reason=`, and a person wants a sentence.
#
# `reason` comes from a closed enumeration. A code that is not in it fails the step rather
# than being written, because the value of a closed set is that a reader can enumerate the
# answers -- and a set that grows silently at each call site is not closed. Adding a reason
# means adding it here, where every reader can see the whole list.

set -euo pipefail

readonly OUTCOMES=(acted no-action handed-to-human failed)

readonly REASONS=(
  # A change advanced, or a job did the thing it exists to do.
  acted
  dispatched
  merged
  # The gate found nothing to stop the change and this repository does not merge that
  # branch unattended, so the pull request waits for a person with its labels intact.
  approved
  promoted
  labelled
  # The change is ready and the forge owns the merge now: a repository rule is holding the
  # pull request, auto-merge is armed, and it lands when the rule is satisfied (FR-080).
  merge-armed
  # The gate in shadow on a person's pull request posted its advisory verdict and changed
  # nothing (feature 007 X11, FR-027).
  advised
  # Nothing to do, and why not.
  # The shadow gate had no verdict to give: the agent did not finish, or answered with
  # something advice cannot be (FR-027).
  no-verdict
  soak-pending
  # Refine said another issue must land first and it has not (feature 007 X12).
  blocked
  hold
  rollback
  hotfix
  already-present
  no-eligible-change
  no-route
  not-a-stage
  no-linked-issue
  missing-required-label
  duplicate-in-flight
  clear-to-proceed
  nothing-to-sweep
  # Every stage carries the content of the ones after it, so there is nothing to carry back
  # down the chain (FR-079).
  stages-aligned
  # A human is needed, or the machinery could not proceed.
  conflict-handed-off
  review-requested
  # A reviewer asked for changes on the pull request; apply-review answers it, not the gate
  # (T246). Missing from this list until 20/11/2026, so the gate's step failed on first use.
  changes-requested
  # The implementing worker asked the kit for the whole change and the kit declined:
  # refused before it wrote anything, or failed its own gates after. Its reason token
  # is its own vocabulary and belongs in the detail sentence, not in this set -- what
  # this loop did is the same either way, which is hand the issue back.
  pipeline-declined
  # The canary cycle's two ways to fail (FR-060): a hop that never happened within its bound,
  # and a hop that happened wrongly.
  timed-out
  assertion-failed
  # The forge refused a token outright, or its API budget ran out. Both used to read as
  # `timed-out` after an hour of polling an answer that was never coming (007 APP-03, QA-10);
  # an expired key on the canary in 2026 looked like a quiet day for two months.
  credential-refused
  rate-limited
  budget-exhausted
  egress-blocked
  runner-offline
  # The runner preflight's own two, which it writes inline: it runs before anything is
  # checked out, so it cannot call a local action.
  runners-online
  runner-unverifiable
  # The worker's activation failed, so no agent ran and no later job could release the issue
  # (agentic-loop-evals #34, 23/11/2026).
  activation-failed
  not-authorised
  invalid-input
)

in_list() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] || continue
    return 0
  done
  return 1
}

: "${OUTCOME:?record-outcome: OUTCOME is required}"
: "${REASON:?record-outcome: REASON is required}"

ROUTE="${ROUTE:--}"
SUBJECT="${SUBJECT:--}"
DETAIL="${DETAIL:-}"

if ! in_list "$OUTCOME" "${OUTCOMES[@]}"; then
  echo "::error::record-outcome: '${OUTCOME}' is not an outcome. One of: ${OUTCOMES[*]}." >&2
  exit 1
fi

if ! in_list "$REASON" "${REASONS[@]}"; then
  echo "::error::record-outcome: '${REASON}' is not in the reason enumeration. Add it to loops/actions/record-outcome/record-outcome.sh, where every reader can see the whole list, or use one of: ${REASONS[*]}." >&2
  exit 1
fi

line="outcome=${OUTCOME} route=${ROUTE} subject=${SUBJECT} reason=${REASON}"

{
  echo "${line}"
  [ -z "$DETAIL" ] || echo "${DETAIL}"
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# The annotations are the difference between a summary somebody has to open and an answer
# on the run's own page. They are also the metrics contract (feature 006 FR-007, review QA-01):
# every outcome is an annotation, `acted` included, so a collector reads one check run's
# annotations instead of downloading and scraping job logs -- the most expensive call the forge
# offers, and the one the rate limit runs out on.
case "$OUTCOME" in
  handed-to-human) echo "::warning::${line}${DETAIL:+ -- }${DETAIL}" ;;
  failed) echo "::error::${line}${DETAIL:+ -- }${DETAIL}" ;;
  *) echo "::notice::${line}${DETAIL:+ -- }${DETAIL}" ;;
esac
