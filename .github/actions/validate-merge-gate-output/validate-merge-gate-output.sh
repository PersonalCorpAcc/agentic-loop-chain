#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/validate-merge-gate-output/validate-merge-gate-output.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
# Print the deterministic merge-gate outcome: merge, approve, review, remediated, or invalid.
#
# `merge` and `approve` are the same judgement about the change and different answers to
# what happens next, which is the repository's policy rather than the agent's (FR-035).
# Both are accepted here whatever the policy says, because the workflow decides what to do
# with them: a gate that called the agent invalid for saying `merge` where nothing
# auto-merges would throw away a perfectly good assessment over a word.

set -euo pipefail

output_file="$1"
# The number the comment had to be on. An issue for an ordinary pull request; the pull
# request itself for a promotion, which carries a set of issues and belongs to none of them
# (FR-056). Nothing here cares which: a comment is matched by the number it targets.
issue_number="$2"
ci_conclusion="$3"

if [ ! -f "$output_file" ] || ! jq -e '.items | arrays' "$output_file" >/dev/null 2>&1; then
  echo invalid
  exit 0
fi

# The agent emits exactly one comment on the source issue. Its verdict tells the
# workflow which App-token state transition to perform.
jq -r --arg issue "$issue_number" --arg conclusion "$ci_conclusion" '
  .items as $items
  | ($items
    | [.[] | select(.type == "add_comment" and (.item_number | tostring) == $issue and (.body | type == "string"))]
    | map(.body |
        if test("\\*\\*Verdict:\\*\\*\\s*(merge|approve|review|remediated)($|[^a-zA-Z_-])"; "i") then
          capture("\\*\\*Verdict:\\*\\*\\s*(?<v>merge|approve|review|remediated)($|[^a-zA-Z_-])"; "i").v | ascii_downcase
        else empty end
      )
    | .[0] // "invalid") as $outcome
  | ([$items[] | select(.type == "push_to_pull_request_branch")] | length) as $pushes
  | if $outcome == "merge" and $conclusion == "success" and $pushes == 0 then "merge"
    elif $outcome == "approve" and $conclusion == "success" and $pushes == 0 then "approve"
    elif $outcome == "remediated" and $conclusion == "failure" and $pushes == 1 then "remediated"
    elif $outcome == "review" and $pushes == 0 then "review"
    else "invalid"
    end
' "$output_file"
