#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/label-estimates/label-estimates.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Turn the estimate refine wrote into each body into an `sp-N` label: the parent always, and
# under a split every child too. Estimates become labels here rather than in the agent, because
# labels are workflow-owned state.
#
# The estimate is read from the `<!-- estimate: N -->` marker, or failing that from the
# readable `**Estimate:** N` line. Only Fibonacci points up to 21 are labels; anything else is
# a warning and no label. A previous `sp-*` label is removed, because a re-refine re-estimates.
#
# Environment: GH_TOKEN, REPO, PARENT (the refined issue), OUTCOME (`complete` or `split`).

set -euo pipefail

label_one() {
  local issue="$1"
  local body points
  body=$(gh issue view "$issue" --repo "$REPO" --json body --jq '.body // ""')
  points=$(printf '%s' "$body" | grep -oE '<!-- estimate: [0-9]+ -->' | head -1 | grep -oE '[0-9]+' || true)
  # The agent writes the readable line every time and the HTML marker only sometimes, so read
  # the line too rather than leaving the issue with no estimate label at all.
  [ -n "$points" ] || points=$(printf '%s' "$body" | grep -oiE '\*\*estimate:\*\*[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$points" ]; then
    echo "::warning::#$issue carries no estimate marker; no points label applied."
    return 0
  fi
  case "$points" in
    1|2|3|5|8|13|21) ;;
    *) echo "::warning::#$issue estimate '$points' is not a Fibonacci point value; skipping."; return 0 ;;
  esac
  # A re-refine re-estimates, so the previous value must not linger beside the new one.
  for old in $(gh issue view "$issue" --repo "$REPO" --json labels --jq '.labels[].name | select(startswith("sp-"))'); do
    [ "$old" = "sp-$points" ] || gh issue edit "$issue" --repo "$REPO" --remove-label "$old" >/dev/null
  done
  gh label create "sp-$points" --repo "$REPO" --color BFD4F2 \
    --description "Story points: $points (about $points human days)" >/dev/null 2>&1 || true
  gh issue edit "$issue" --repo "$REPO" --add-label "sp-$points" >/dev/null
  echo "#$issue estimated at $points point(s)"
}

label_one "$PARENT"

# safe_outputs links every child as a sub-issue of the parent, and the tool writes that link
# rather than the agent, so it is there even when the body marker the agent was asked for is
# missing, which is the usual case. The marker search stays as a fallback.
list_children() {
  local found
  found=$(gh api "repos/$REPO/issues/$PARENT/sub_issues" --jq '.[].number' 2>/dev/null || true)
  if [ -z "$found" ]; then
    found=$(gh issue list --repo "$REPO" --state open --limit 50 \
      --search "\"<!-- split-parent: ${PARENT} -->\" in:body" --json number --jq '.[].number' || true)
  fi
  printf '%s\n' "$found"
}

if [ "$OUTCOME" = "split" ]; then
  for child in $(list_children); do
    [ "$child" = "$PARENT" ] && continue
    label_one "$child"
  done
fi
