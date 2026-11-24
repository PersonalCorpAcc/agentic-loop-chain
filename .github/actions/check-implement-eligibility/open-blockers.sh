#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-implement-eligibility/open-blockers.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The blockers of an issue that have not landed yet, as `#M #N` on one line (empty when none),
# FR-151. Reads the issue body on stdin; its blockers are what list-blockers.sh finds.
#
# A blocker has landed when its issue is closed, or when a pull request carrying its
# `implement-issue` marker has merged into BASE_BRANCH, the branch implement starts from. The
# dependent change is built on that branch, so that is where the blocker's code has to be. An
# issue closes only when its change reaches the last stage, so on a multi-stage repository
# waiting for the close held a dependent story for a whole promotion cycle, gates included,
# after its blocker's code was already in the base branch (loopscope #458 behind #457,
# 24/11/2026).
#
# Fails closed: a blocker whose state cannot be read is open, and a merged-pull-request list
# that cannot be read counts as no merges. Exits non-zero when the body cannot be parsed, so a
# caller never reads "no blockers" from a parser that did not run.
#
# Environment: GH_TOKEN, REPO (else GITHUB_REPOSITORY), BASE_BRANCH (empty: only a closed
# issue has landed).
set -euo pipefail

repo="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY is required}}"
base="${BASE_BRANCH:-}"

blockers=$(bash "$(dirname "${BASH_SOURCE[0]}")/list-blockers.sh")

merged=""
merged_read=false
open=""
for blocker in $blockers; do
  state=$(gh issue view "$blocker" --repo "$repo" --json state --jq .state 2>/dev/null || echo UNKNOWN)
  [ "$state" = "CLOSED" ] && continue
  if [ -n "$base" ] && [ "$merged_read" = false ]; then
    # Issue numbers named by the markers of pull requests merged into the base branch, read
    # once and only when some blocker is still open.
    merged=$(gh api "repos/$repo/pulls?state=closed&base=$base&per_page=100" --paginate \
      --jq '.[] | select(.merged_at != null) | .body // "" | scan("<!-- implement-issue: *([0-9]+) *-->") | .[0]' 2>/dev/null || true)
    merged_read=true
  fi
  grep -qx "$blocker" <<<"$merged" && continue
  open="${open} #${blocker}"
done
printf '%s\n' "${open# }"
