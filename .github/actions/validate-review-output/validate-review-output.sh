#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/validate-review-output/validate-review-output.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
# Print implemented, already-satisfied, needs-human, or invalid.

set -euo pipefail

output_file="$1"
pr_number="$2"
# The threads as they were **before** the agent ran. A push outdates the thread it fixes, so
# a set read after the run is empty exactly when the work succeeded (T245).
threads_file="$3"

if [ ! -f "$output_file" ] || [ ! -f "$threads_file" ] \
  || ! jq -e '.items | arrays' "$output_file" >/dev/null 2>&1 \
  || ! jq -e 'type == "array"' "$threads_file" >/dev/null 2>&1; then
  echo invalid
  exit 0
fi

jq -r --arg pr "$pr_number" --slurpfile threads "$threads_file" '
  .items as $items
  | ($threads[0] | map(select(.isResolved == false and .isOutdated == false) | .id) | sort) as $expected
  | ($items | [.[] | select(.type == "add_comment" and (.item_number | tostring) == $pr and (.body | type == "string"))]) as $comments
  | ($comments | map(.body | if test("\\*\\*Review outcome:\\*\\*\\s*(implemented|already-satisfied|needs-human)"; "i") then capture("\\*\\*Review outcome:\\*\\*\\s*(?<v>implemented|already-satisfied|needs-human)"; "i").v | ascii_downcase else empty end) | .[0] // "invalid") as $outcome
  # `scan` without captures emits one string per match and `map` collects every output, so
  # this is already a flat array: `add` would concatenate the ids into a single string, and
  # `unique` on a string is an error rather than a verdict.
  | ([$comments[].body | scan("PRRT_[A-Za-z0-9_=-]+")] | unique | sort) as $reported
  | ([$items[] | select(.type == "push_to_pull_request_branch")] | length) as $pushes
  | if $expected != $reported then "invalid"
    elif $outcome == "implemented" and $pushes == 1 then "implemented"
    elif ($outcome == "already-satisfied" or $outcome == "needs-human") and $pushes == 0 then $outcome
    else "invalid"
    end
' "$output_file"
