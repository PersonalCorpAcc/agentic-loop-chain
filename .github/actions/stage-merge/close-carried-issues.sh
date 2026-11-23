#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/stage-merge/close-carried-issues.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Close every issue a change carried into the stage this repository ends on (FR-051).
#
# Under `env-promotion` the merge that reaches the closing stage reaches it for all of them at
# once. One `gh` call each, and a close that fails does not take the rest with it: the issues are
# independent and a half-closed set with an error is better than a set nobody closed.
#
# Environment: GH_TOKEN, REPO, ISSUES (one per line).

set -euo pipefail
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  if gh issue close "$issue" --repo "$REPO" --reason completed; then
    echo "Issue #${issue} closed: its change reached the stage this repository ends on."
  else
    echo "::warning::Issue #${issue} reached the closing stage but could not be closed."
  fi
done <<< "$ISSUES"
