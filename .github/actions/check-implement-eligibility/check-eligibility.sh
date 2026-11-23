#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-implement-eligibility/check-eligibility.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is this issue one implement should start on now? Writes `eligible=true|false` to
# GITHUB_OUTPUT, and `blocked_by=#M #N` when open blockers are why it is not.
#
# Not when it is closed, not when it carries the `future` label, and not while an issue it
# names as `Blocked by #M` is still open (feature 007 X12).
#
# Environment: GH_TOKEN, ISSUE_NUMBER, GITHUB_REPOSITORY, GITHUB_OUTPUT.

set -euo pipefail

labels=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --json labels \
  --jq '[.labels[].name]')

# A queued run executes long after it was dispatched, and the issue can be closed in between.
# Without this check the run claims a closed issue, burns an agent run on it and opens a pull
# request nobody asked for.
state=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --json state --jq .state)
if [ "$state" = "CLOSED" ]; then
  echo "eligible=false" >> "$GITHUB_OUTPUT"
  echo "::notice::Issue #$ISSUE_NUMBER is closed. Automated implementation skipped."
  exit 0
fi

if jq -e 'index("future")' >/dev/null <<<"$labels"; then
  echo "eligible=false" >> "$GITHUB_OUTPUT"
  echo "::notice::Issue #$ISSUE_NUMBER has the future label. Automated implementation skipped."
  exit 0
fi

# Refine writes `Blocked by #M` when order genuinely matters (feature 007 X12). Nothing read
# it, so a child could be implemented before the sibling it builds on had landed. A blocker
# counts until it is closed; one that cannot be read counts as open.
body=$(gh issue view "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --json body --jq '.body // ""')
open_blockers=""
for blocker in $(grep -oiE 'blocked by #[0-9]+' <<<"$body" | grep -oE '[0-9]+' | sort -un || true); do
  blocker_state=$(gh issue view "$blocker" --repo "$GITHUB_REPOSITORY" --json state --jq .state 2>/dev/null || echo UNKNOWN)
  [ "$blocker_state" = "CLOSED" ] || open_blockers="${open_blockers} #${blocker}"
done
if [ -n "$open_blockers" ]; then
  echo "eligible=false" >> "$GITHUB_OUTPUT"
  echo "blocked_by=${open_blockers# }" >> "$GITHUB_OUTPUT"
  echo "::notice::Issue #$ISSUE_NUMBER is blocked by${open_blockers}; it starts when they close."
  exit 0
fi

echo "eligible=true" >> "$GITHUB_OUTPUT"
