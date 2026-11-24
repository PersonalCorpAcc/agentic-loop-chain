#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-implement-eligibility/hold-for-blockers.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Hold an issue for its blockers (feature 007 X12): release the working label, because an issue
# must not look in progress with nothing running, and say once what it is waiting for. It keeps
# the implement label; the router's hourly sweep starts it again when its blockers close.
#
# Environment: GH_TOKEN, GITHUB_REPOSITORY, ISSUE_NUMBER, BLOCKED_BY (e.g. "#12, #13"),
# WORKING_LABEL, IMPLEMENT_LABEL.

set -euo pipefail
gh issue edit "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --remove-label "$WORKING_LABEL" || true
marker="<!-- implement-held-for-blockers -->"
already=$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments?per_page=100" --paginate \
  --jq ".[] | select(.body | contains(\"$marker\")) | .id" | grep -c . || true)
if [ "${already:-0}" -eq 0 ]; then
  gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body "${marker}
Held: this issue is blocked by ${BLOCKED_BY}, which must land first. It keeps \`${IMPLEMENT_LABEL}\` and starts on its own once every blocker is closed."
fi
