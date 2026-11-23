#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/gate-review/review-blocked.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Does a change request hold this pull request for a person? Writes `review_blocked=true|false`.
#
# The forge's own answer first: `reviewDecision` is CHANGES_REQUESTED while any reviewer's change
# request stands. Under `gate.mode: review` the gate makes change requests of its own, for
# apply-review to answer (feature 007 X08, FR-024), and the next gate run must not read its own
# request as a person's and leave the pull request alone: that would hold every fix it asked for.
# So when the forge says CHANGES_REQUESTED, the standing requests are read -- each reviewer's
# latest decisive review -- and the ones the gate wrote, a bot's review carrying its marker, are
# set aside. Anything left is a person's, and blocks, as it always did.
#
# Inputs: REPO, PR, GH_TOKEN, GATE_REVIEW_MARKER. A read that fails three times is not blocked,
# as before: the agent re-reads the review state itself before any merge.

set -euo pipefail

: "${REPO:?review-blocked: REPO is required}"
: "${PR:?review-blocked: PR is required}"
marker="${GATE_REVIEW_MARKER:-<!-- agent-merge-gate-review -->}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

decision=""
for _ in 1 2 3; do
  if decision=$(gh pr view "$PR" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""'); then
    break
  fi
  sleep "${REVIEW_POLL_SECONDS:-5}"
done

if [ "$decision" != CHANGES_REQUESTED ]; then
  echo "review_blocked=false" >>"$out"
  exit 0
fi

if ! reviews="$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews?per_page=100" | jq -s 'add // []')"; then
  echo "::warning::Could not read the reviews on PR #${PR}; the forge says changes are requested, so the gate leaves it alone."
  echo "review_blocked=true" >>"$out"
  exit 0
fi

# Each reviewer's latest decisive review; the change requests among them that are not the gate's.
people="$(MARKER="$marker" jq -r '
  [.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
  | group_by(.user.login) | map(last) | map(select(.state == "CHANGES_REQUESTED"))
  | map(select((.user.type == "Bot" and ((.body // "") | contains(env.MARKER))) | not))
  | .[].user.login' <<<"$reviews" | tr -d '\r')"

if [ -n "$people" ]; then
  echo "review_blocked=true" >>"$out"
  echo "A change request stands on PR #${PR} from: $(printf '%s' "$people" | tr '\n' ' ')"
else
  echo "review_blocked=false" >>"$out"
  echo "The only change request standing on PR #${PR} is the merge gate's own; it does not hold the gate."
fi
