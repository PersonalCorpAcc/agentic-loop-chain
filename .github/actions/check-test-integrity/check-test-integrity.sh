#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-test-integrity/check-test-integrity.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
# Report, one line each, the ways a change weakens the repository's tests: a test file deleted,
# a test file renamed out of the test pattern, or a skip marker added to a test file.
#
# Deterministic, so the gate does not have to notice it (Principle III; feature 007 X06). An
# agent that cannot make a test pass and deletes or skips it instead produces a green run that
# proves nothing; a model reviewer may or may not see it, and this always does. Every line
# printed hands the pull request to a person, as a protected file does.
#
# Usage: check-test-integrity.sh <compare.json> <test-file pattern> <skip-marker pattern>
#   compare.json  the compare endpoint's answer ({ "files": [...] }) or a pull request's own
#                 file list ([...]); each file has filename, status, previous_filename, patch
#   patterns      extended regular expressions, as grep -E reads them, composed by the
#                 installer from the declared stack packs. An empty test-file pattern means no
#                 pack declared one, and nothing is checked.

set -euo pipefail

compare_file="$1"
test_files="${2:-}"
skip_markers="${3:-}"

[ -n "$test_files" ] || exit 0
[ -s "$compare_file" ] || exit 0

is_test() { printf '%s\n' "$1" | grep -qE -- "$test_files"; }

while IFS= read -r file; do
  [ -n "$file" ] || continue
  name=$(jq -r '.filename // ""' <<<"$file")
  status=$(jq -r '.status // ""' <<<"$file")
  previous=$(jq -r '.previous_filename // ""' <<<"$file")

  if [ "$status" = "removed" ] && is_test "$name"; then
    echo "test file deleted: $name"
    continue
  fi
  if [ "$status" = "renamed" ] && [ -n "$previous" ] && is_test "$previous" && ! is_test "$name"; then
    echo "test file renamed out of the test pattern: $previous -> $name"
    continue
  fi
  if [ -n "$skip_markers" ] && is_test "$name"; then
    # Added lines only: a marker the change removes, or one already there, is not this change's.
    # Collected first and matched second: `grep -q` in a pipeline under pipefail exits on the
    # first match, its writer dies of SIGPIPE, and the pipeline reports failure on a hit.
    added_lines=$(jq -r '.patch // ""' <<<"$file" | grep -E '^\+' | grep -vE '^\+\+\+' || true)
    if [ -n "$added_lines" ] && grep -qE -- "$skip_markers" <<<"$added_lines"; then
      echo "skip marker added: $name"
    fi
  fi
done < <(jq -c '(if type == "array" then . else (.files // []) end)[]' "$compare_file")
