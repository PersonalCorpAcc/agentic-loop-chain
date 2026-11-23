#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/await-pr-landing/await-pr-landing.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Hold the implement slot until this issue's pull request merges, closes, or is handed to a
# person, or until MAX_WAIT_MINUTES pass (FR-054). Always exits 0: the slot is released either
# way, and a timeout is a warning rather than a failure.
#
# Environment: GH_TOKEN, REPO, ISSUE, REVIEW_LABEL, MAX_WAIT_MINUTES, LINKED_PR (the App's
# recorded linkage, may be empty), POLL_SECONDS (default 30).

set -euo pipefail

poll="${POLL_SECONDS:-30}"

# The App's own comment first, then the pull request that carries this issue's marker. The
# keyword search that used to be the fallback finds nothing now and would have looked like
# "no pull request": this loop stops writing keywords, because the forge closes an issue on one
# at the first merge (FR-030, FR-064).
pr="${LINKED_PR:-}"
if [ -z "$pr" ]; then
  pr=$(gh pr list --repo "$REPO" --state open --json number,body \
    --jq "[.[] | select((.body // \"\") | contains(\"<!-- implement-issue: ${ISSUE} -->\"))][0].number // empty")
fi
if [ -z "$pr" ]; then
  echo "::notice::No pull request found for #$ISSUE; nothing to wait for."
  exit 0
fi

echo "Holding the implement slot until PR #$pr lands."
deadline=$(( $(date +%s) + MAX_WAIT_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  state=$(gh pr view "$pr" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo GONE)
  case "$state" in
    MERGED)
      echo "::notice::PR #$pr merged. Releasing the slot so the next story branches from it."
      exit 0 ;;
    CLOSED|GONE)
      echo "::notice::PR #$pr is $state. Releasing the slot."
      exit 0 ;;
  esac
  # A human now owns the change, so the queue must not wait on them.
  if gh issue view "$ISSUE" --repo "$REPO" --json labels \
    --jq '[.labels[].name]' | jq -e --arg l "$REVIEW_LABEL" 'index($l)' >/dev/null; then
    echo "::notice::#$ISSUE was handed to a human ($REVIEW_LABEL). Releasing the slot."
    exit 0
  fi
  sleep "$poll"
done
echo "::warning::PR #$pr did not land within ${MAX_WAIT_MINUTES}m. Releasing the slot; the next story may branch from a default branch without these changes."
