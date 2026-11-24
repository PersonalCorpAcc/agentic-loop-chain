#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/resolve-merge-base/resolve-merge-base.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Which branch is this gate's pull request aimed at? The merge belt's lock is keyed on it
# (FR-033). Never answers with nothing: an empty key puts every gate back into one queue.
#
# Environment: GH_TOKEN, REPO, PR_NUMBER (may be empty), DISPATCH_BASE (may be empty),
# KNOWN_BRANCHES (comma-separated), FALLBACK_BASE. Output: base.

set -euo pipefail
base=""

# The forge first. It is the only authority on what a pull request targets, and a branch name
# typed into a dispatch box is a guess about it.
if [ -n "${PR_NUMBER:-}" ]; then
  base="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
fi

# Then the dispatch input, for a gate dispatched without a pull request the forge will answer
# for. Checked against the branches this repository actually lands work on: an unknown value
# would get a lock all to itself, which is the same as no lock, and the belt exists precisely
# so that cannot happen.
if [ -z "$base" ] && [ -n "${DISPATCH_BASE:-}" ]; then
  while IFS= read -r known; do
    [ "$known" = "$DISPATCH_BASE" ] || continue
    base="$DISPATCH_BASE"
    break
  done < <(printf '%s\n' "$KNOWN_BRANCHES" | tr ',' '\n')
  [ -n "$base" ] ||
    echo "::warning::Ignoring base-branch '${DISPATCH_BASE}': it is not one of ${KNOWN_BRANCHES}."
fi

# Then the profile's own base, so the key is never empty. An empty key does not fail: it puts
# every gate back into one queue, quietly, which is the behaviour this job exists to end.
base="${base:-$FALLBACK_BASE}"
echo "base=$base" >> "$GITHUB_OUTPUT"
echo "The merge belt for this run is keyed on '${base}'."
