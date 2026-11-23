#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/decide-person-review.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# A protected file or a test-integrity finding hands the pull request to a person (007 X06).
#
# Environment: PROTECTED, FINDINGS (each one per line, may be empty).
# Outputs: requires_review, files (one per line).

set -euo pipefail
listed=$(printf '%s\n%s\n' "$PROTECTED" "$FINDINGS" | grep -v '^$' || true)
if [ -n "$listed" ]; then
  echo "requires_review=true" >> "$GITHUB_OUTPUT"
  {
    echo 'files<<EOF'
    printf '%s\n' "$listed"
    echo EOF
  } >> "$GITHUB_OUTPUT"
else
  echo "requires_review=false" >> "$GITHUB_OUTPUT"
  echo "files=" >> "$GITHUB_OUTPUT"
fi
