#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-implement-eligibility/find-existing-change.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Does this issue already have a change from this loop that a new implement would duplicate?
# Writes `open=true|false` to GITHUB_OUTPUT.
#
# `open=true` for a linked pull request that is open, and for one that merged while the issue
# is neither held nor rolled back: that change is travelling through the stages, and another
# implement would build it twice (#184 duplicated the merged #183 on loopscope, 20/11/2026).
#
# Environment: GH_TOKEN, REPO, ISSUE_NUMBER, LINKED_PR (the App's recorded linkage, may be
# empty), HOLD_LABEL, ROLLBACK_LABEL, GITHUB_OUTPUT.

set -euo pipefail

if [ -z "${LINKED_PR:-}" ]; then
  echo "open=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
state=$(gh pr view "$LINKED_PR" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)
if [ "$state" = "OPEN" ]; then
  echo "open=true" >> "$GITHUB_OUTPUT"
  echo "::notice::#${ISSUE_NUMBER} already has open pull request #${LINKED_PR} from this loop. This run stops rather than opening a second one."
elif [ "$state" = "MERGED" ] && ! gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' \
    | grep -qxE "${HOLD_LABEL}|${ROLLBACK_LABEL}"; then
  # Merged and travelling: a re-implement is wanted only once the change is held or rolled back.
  echo "open=true" >> "$GITHUB_OUTPUT"
  echo "::notice::#${ISSUE_NUMBER} already has merged pull request #${LINKED_PR}, and the issue is neither held nor rolled back. This run stops rather than implementing it again."
else
  # Closed unmerged, or merged and then held or rolled back: a re-implement is legitimate.
  echo "open=false" >> "$GITHUB_OUTPUT"
fi
