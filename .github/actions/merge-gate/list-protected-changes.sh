#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/list-protected-changes.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Which files this pull request changes that the profile protects, compared against the
# merge base as it is now (FR-022, FR-083). The comparison is kept whole for the
# test-integrity check.
#
# Environment: GH_TOKEN, REPO, PR, BASE, PROTECTED_FILES (an extended regular expression),
# RUNNER_TEMP.
# Outputs: compare_file, files (one per line).

set -euo pipefail
# Compared against the merge base as it is now, rather than read from the pull
# request's own file list (FR-083).
#
# A pull request keeps the base it was opened against. When the base branch's
# history moves -- a back-merge, a realignment, anything that is not a fast-forward
# of what it had -- `pulls/{n}/files` goes on answering from the old merge base,
# for ever: on the canary on 18/09/2026 it reported 83 changed files where git said
# two, and neither a `synchronize` event nor twenty minutes shifted it. This rule
# decides whether a person must look at a change, so reading a stale list means
# handing over work nobody needed to do -- and, in the other direction, a rule that
# is wrong in one direction is not one anybody should trust in the other.
#
# The three-dot compare is computed when it is asked for, so it cannot go stale.
head_sha=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
# Kept whole for the test-integrity check, which reads each file's status and patch.
compare_file="${RUNNER_TEMP:-/tmp}/compare.json"
gh api "repos/$REPO/compare/${BASE}...${head_sha}" > "$compare_file" || true
files=$(jq -r '.files[]?.filename' "$compare_file" 2>/dev/null || true)
# The compare endpoint stops at 300 files and says so by giving exactly that many.
# Past it the pull request's own list is the only one available, stale or not, and a
# change that large is one a person should see anyway.
if [ "$(printf '%s\n' "$files" | grep -c .)" -ge 300 ]; then
  echo "::warning::PR #${PR} changes 300 files or more, which is the compare limit; falling back to the pull request's own file list."
  gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" | jq -s 'add' > "$compare_file"
  files=$(jq -r '.[].filename' "$compare_file")
fi
echo "compare_file=$compare_file" >> "$GITHUB_OUTPUT"
protected=$(printf '%s\n' "$files" | grep -E "$PROTECTED_FILES" || true)
{
  echo 'files<<EOF'
  printf '%s\n' "$protected"
  echo EOF
} >> "$GITHUB_OUTPUT"
