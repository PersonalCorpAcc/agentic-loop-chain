#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/fetch-gate-context.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Everything the gate's agent reads about the pull request, written before it starts: the
# diff, the pull request, what the head is missing from its base (FR-068), and the failing
# CI logs when CI failed.
#
# Environment: GH_TOKEN, REPO, PR, RUN_ID, CONCLUSION, AGENT_DIR (default /tmp/gh-aw/agent).
# Writes: diff.patch, pr.json, base-state.txt, and failed-logs.txt and failed-jobs.json.

set -euo pipefail
dir="${AGENT_DIR:-/tmp/gh-aw/agent}"
mkdir -p "$dir"
# gh 2.97 refuses to print a diff holding a terminal escape sequence, so a pull request
# that adds one (a test stripping colour codes, loopscope #348) crashed this step. The file
# is read as text, not shown on a terminal: pass the flag wherever this gh offers it.
diff_flags=()
if gh pr diff --help 2>&1 | grep -q -- '--allow-escape-sequences'; then diff_flags=(--allow-escape-sequences); fi
gh pr diff "$PR" --repo "$REPO" "${diff_flags[@]}" > "$dir/diff.patch"
gh pr view "$PR" --repo "$REPO" --json title,body,files,additions,deletions \
  > "$dir/pr.json"

# What this working tree is not. The agent is on the head branch; CI ran on the merge of
# head and base. Everything the base supplies -- a dependency, a tsconfig path, a
# generated file -- is absent here, so a build run in this tree can fail for reasons that
# do not exist in what will land. Recorded rather than inferred, because the agent cannot
# see it and has already argued itself past a green CI run without it (PR #55).
base=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch -q origin "$base" 2>/dev/null || true
behind=$(git rev-list --count "HEAD..origin/$base" 2>/dev/null || echo "unknown")
{
  echo "base branch: $base"
  echo "commits on the base that this branch does not have: $behind"
  if [ "$behind" != "unknown" ] && [ "$behind" != "0" ]; then
    echo "files those commits touch:"
    git diff --name-only "HEAD...origin/$base" 2>/dev/null | head -50
  fi
} > "$dir/base-state.txt"
if [ "$CONCLUSION" = "failure" ] && [ -n "$RUN_ID" ]; then
  gh run view "$RUN_ID" --repo "$REPO" --log-failed \
    > "$dir/failed-logs.txt" 2>/dev/null || \
    echo "logs unavailable" > "$dir/failed-logs.txt"
  gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | {name, conclusion}]' \
    > "$dir/failed-jobs.json"
elif [ "$CONCLUSION" = "failure" ]; then
  echo "[]" > "$dir/failed-jobs.json"
  echo "CI run ID unavailable, cannot fetch logs" > "$dir/failed-logs.txt"
fi
