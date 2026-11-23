#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-pr-verification/check-pr-verification.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Proof of work (feature 007 X09): does the pull request say what was tested and what was not?
# A body with a `## Verification` heading and both a `Tested:` and a `Not tested:` line passes;
# anything else gets one comment saying its checks are unstated, and a warning. Never fails.
#
# Environment: GH_TOKEN, PR_NUMBER, GITHUB_REPOSITORY.

set -euo pipefail

body=$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json body --jq '.body // ""')
if grep -qE '^## Verification' <<<"$body" && grep -qE '^Tested:' <<<"$body" && grep -qE '^Not tested:' <<<"$body"; then
  echo "PR #$PR_NUMBER states what was tested and what was not."
  exit 0
fi
marker="<!-- implement-no-verification -->"
gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body "${marker}
The implementing agent did not say what it tested: this pull request has no \`## Verification\` section with \`Tested:\` and \`Not tested:\` lines. Treat its checks as unstated, and rely on CI and the review rather than on the description."
echo "::warning::PR #$PR_NUMBER does not state what was tested."
