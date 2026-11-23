#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/gate-review/dismiss-gate-reviews.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Under `gate.mode: review` the gate's own change requests are answered by apply-review, and when
# the gate finds the pull request clean they are done with (feature 007 X08, FR-024). They are
# dismissed here, before anything merges, so that neither the forge's review decision nor a
# person reading the pull request is left with a request nobody is going to withdraw. Dismissed
# rather than approved over: an approval by the App could count towards a rule that requires a
# person's, which is a human gate the loop must not satisfy for itself.
#
# Only the gate's: a bot's change request carrying its marker that still stands. A person's is
# never touched. Best effort: a protected branch may allow only some people to dismiss, and the
# gate's own review_blocked check already sets these aside, so a refusal is a warning.
#
# Inputs: REPO, PR, GH_TOKEN (the App's), GATE_REVIEW_MARKER.

set -euo pipefail

: "${REPO:?dismiss-gate-reviews: REPO is required}"
: "${PR:?dismiss-gate-reviews: PR is required}"
marker="${GATE_REVIEW_MARKER:-<!-- agent-merge-gate-review -->}"

reviews="$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews?per_page=100" | jq -s 'add // []')"
mapfile -t standing < <(MARKER="$marker" jq -r '
  [.[] | select(.state == "CHANGES_REQUESTED" and .user.type == "Bot" and ((.body // "") | contains(env.MARKER)))]
  | .[].id' <<<"$reviews" | tr -d '\r')

if [ "${#standing[@]}" -eq 0 ]; then
  echo "No change request of the gate's stands on PR #${PR}."
  exit 0
fi

for id in "${standing[@]}"; do
  [ -n "$id" ] || continue
  if gh api -X PUT "repos/${REPO}/pulls/${PR}/reviews/${id}/dismissals" \
    -f message="The merge gate found the requested changes made." -f event=DISMISS >/dev/null; then
    echo "Dismissed the gate's change request ${id} on PR #${PR}."
  else
    echo "::warning::Could not dismiss the gate's change request ${id} on PR #${PR}; a person with dismissal rights can."
  fi
done
