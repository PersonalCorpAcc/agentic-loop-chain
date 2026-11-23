#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/check-merge-conflicts.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Does this pull request conflict with its base? (FR-108)
#
# Environment: GH_TOKEN, REPO, PR, POLL_SECONDS (default 5).
# Output: has_conflicts.

set -euo pipefail
# GitHub computes mergeability lazily and answers UNKNOWN to the first question after
# the base moves, which read as "no conflict": on loopscope (20/11/2026) the gate saw a
# DIRTY pull request as mergeable, found no CI result, and asked for review instead of
# resolving the conflict (FR-108). Ask until it knows, and take a DIRTY merge state as
# a conflict too.
mergeable=UNKNOWN
state=""
for _ in 1 2 3 4 5 6 7 8; do
  read -r mergeable state < <(gh pr view "$PR" --repo "$REPO" --json mergeable,mergeStateStatus \
    --jq '"\(.mergeable) \(.mergeStateStatus)"' 2>/dev/null || echo "UNKNOWN UNKNOWN")
  [ "$mergeable" = "UNKNOWN" ] || break
  sleep "${POLL_SECONDS:-5}"
done
echo "PR #$PR: mergeable=$mergeable, merge state=$state"
if [ "$mergeable" = "CONFLICTING" ] || [ "$state" = "DIRTY" ]; then
  echo "has_conflicts=true" >> "$GITHUB_OUTPUT"
else
  echo "has_conflicts=false" >> "$GITHUB_OUTPUT"
fi
