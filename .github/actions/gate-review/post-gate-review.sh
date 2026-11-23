#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/gate-review/post-gate-review.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The merge gate's change request under `gate.mode: review` (feature 007 X08, FR-024): its
# severity-ranked findings as a pull-request review that requests changes, submitted with the
# App token so the review is an event. The router sends a submitted review to apply-review,
# whose subject step counts this one -- a bot's review carrying the gate's marker -- as the one
# bot change request it answers (FR-118). apply-review makes the change, CI runs, and the gate
# reviews again.
#
# Inputs: REPO, PR, GH_TOKEN (the App's), OUTPUT_FILE, COMMENT_TARGET, GATE_REVIEW_MARKER, ROUND,
# MAX_ROUNDS, RUN_URL. Fails when the forge refuses the review, so the caller can hand the pull
# request to a person instead -- a pull request the App opened itself is one it may not review.

set -euo pipefail

: "${REPO:?post-gate-review: REPO is required}"
: "${PR:?post-gate-review: PR is required}"
marker="${GATE_REVIEW_MARKER:-<!-- agent-merge-gate-review -->}"

body=""
if [ -n "${OUTPUT_FILE:-}" ] && [ -f "$OUTPUT_FILE" ]; then
  body="$(jq -r --arg target "${COMMENT_TARGET:-$PR}" --arg pr "$PR" '
    [.items[]? | select(.type == "add_comment" and (.body | type == "string"))
      | select((.item_number | tostring) as $n | $n == $target or $n == $pr)] | .[0].body // ""' "$OUTPUT_FILE" | tr -d '\r')"
fi
# The agent's assessment is the findings. Its marker lines and its Verdict line are the gate's
# vocabulary on the issue, and in a review body the belt would read them as a second verdict.
findings="$(printf '%s\n' "$body" | { grep -v -e '<!-- agent-merge-gate' || true; } | sed 's/\*\*Verdict:\*\*/**Agent verdict:**/g')"

file="$(mktemp)"
{
  echo "$marker"
  echo "**Merge gate review, round ${ROUND:-1} of ${MAX_ROUNDS:-?}.** The gate does not push in this repository: it asks for what the change needs, apply-review makes it, and the gate reviews again when CI has run. Every blocker and major finding below must be addressed; the minor ones are listed for whoever wants them."
  echo
  printf '%s\n' "$findings"
  echo
  echo "[View this workflow run](${RUN_URL:-})"
} >"$file"

gh pr review "$PR" --repo "$REPO" --request-changes --body-file "$file" >/dev/null
rm -f "$file"
echo "Requested changes on PR #${PR} (round ${ROUND:-1} of ${MAX_ROUNDS:-?})."
