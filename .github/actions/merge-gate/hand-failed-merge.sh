#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/hand-failed-merge.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The gate decided to merge and the merge itself failed (FR-139). Its `merge` verdict is already
# on the pull request and is newer than CI, so no sweep looks at the pull request again: without
# this it stays approved, unmerged and reserved for ever. Say so on the pull request, and hand
# the issue to a person (a promotion carries no single issue, so only the comment).
#
# Reads: GH_TOKEN, REPO, PR, ISSUE, PROMOTION, REVIEW_LABEL, RUN_URL.
set -uo pipefail

gh pr comment "$PR" --repo "$REPO" --body "The merge gate's verdict on this pull request was \`merge\`, but the merge itself failed ([run](${RUN_URL})). Nothing will retry it on its own, so it is handed to a person: merge it, or re-run the gate with the \`merge-gate\` label." >/dev/null ||
  echo "::warning::Could not comment on PR #$PR."

if [ "${PROMOTION:-false}" != true ] && [ -n "${ISSUE:-}" ]; then
  gh issue edit "$ISSUE" --repo "$REPO" --add-label "$REVIEW_LABEL" >/dev/null ||
    echo "::warning::Could not add $REVIEW_LABEL to #$ISSUE."
fi
echo "::error::PR #$PR: the gate approved the merge and the merge failed; handed to a person."
