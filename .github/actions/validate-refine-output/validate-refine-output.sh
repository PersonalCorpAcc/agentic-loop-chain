#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/validate-refine-output/validate-refine-output.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
# Print the deterministic Refine outcome: complete, split, questions, or invalid.

set -euo pipefail

output_file="$1"
marker="$2"
comment_prefix="$3"
issue_number="$4"

if [ ! -f "$output_file" ] || ! jq -e '.items | arrays' "$output_file" >/dev/null 2>&1; then
  echo invalid
  exit 0
fi

jq -r --arg marker "$marker" --arg prefix "$comment_prefix" --arg issue "$issue_number" '
  def has_replacement_body:
    any(.items[]; .type == "update_issue" and
      (.item_number == null or (.item_number | tostring) == $issue) and
      (.body | type == "string") and (.body | test("[^[:space:]]")));

  def has_update:
    any(.items[]; .type == "update_issue");

  # A split writes children, which are the only items allowed to target something other than
  # the source issue: they do not exist yet, so they carry no number at all.
  def child_count:
    ([.items[] | select(.type == "create_issue" and
      (.body | type == "string") and (.body | test("[^[:space:]]")) and
      (.title | type == "string") and (.title | test("[^[:space:]]")))] | length)
    # Children a half-finished earlier run already filed, which normalise-split-output took
    # out of the items so they are not filed twice (FR-114).
    + ((.reused_children // []) | length);

  def has_only_source_items:
    all(.items[];
      (
        .type == "update_issue" and
        (.item_number == null or (.item_number | tostring) == $issue)
      ) or
      (
        .type == "add_comment" and
        (.item_number == null or (.item_number | tostring) == $issue)
      ) or
      .type == "create_issue");

  # A comment that names no issue goes to the triggering one, as an update that names none
  # does: the first questions on the canary arrived with item_number null and were thrown away
  # as no outcome, though the comment itself was posted (20/11/2026). No apostrophes in here:
  # this whole program is one single-quoted shell argument.
  def has_clarification:
    any(.items[]; .type == "add_comment" and
      (.item_number == null or (.item_number | tostring) == $issue) and
      (.body | type == "string") and
      (.body | split($marker) | join("") | split($prefix) | join("") |
        gsub("<[^>]*>"; "") | test("[[:alnum:]]")));

  # Order matters: a run that wrote children is a split even though it also replaced the
  # parent body, and a lone child with no parent update is an incomplete split, not a
  # complete refinement.
  if child_count >= 2 and has_replacement_body and has_only_source_items then "split"
  elif child_count > 0 then "invalid"
  elif has_replacement_body and has_only_source_items then "complete"
  elif has_clarification and (has_update | not) and has_only_source_items then "questions"
  else "invalid"
  end
' "$output_file"
