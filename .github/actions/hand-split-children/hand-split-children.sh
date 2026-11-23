#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/hand-split-children/hand-split-children.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Hand the children of a split to implement, as the App.
#
# safe_outputs writes the children with GITHUB_TOKEN, and a label applied by that token raises
# no labeled event, so the router never sees a child and the split stalls. Re-applying the
# implement label as the App raises the event the classifier routes on; it is removed first,
# because adding a label an issue already carries is a no-op and raises nothing. A child that
# already carries the refined label was handed over earlier and is left alone, or it would start
# a second implement run on work already in flight.
#
# Environment: GH_TOKEN (the App's), REPO, PARENT, REFINE_LABEL, REFINED_LABEL, IMPLEMENT_LABEL.

set -euo pipefail

children=$(gh api "repos/$REPO/issues/$PARENT/sub_issues" --jq '.[].number' 2>/dev/null || true)
if [ -z "$children" ]; then
  children=$(gh issue list --repo "$REPO" --state open --limit 50 \
    --search "\"<!-- split-parent: ${PARENT} -->\" in:body" --json number --jq '.[].number' || true)
fi
for child in $children; do
  [ "$child" = "$PARENT" ] && continue
  if gh issue view "$child" --repo "$REPO" --json labels --jq '.labels[].name' \
    | grep -qx "$REFINED_LABEL"; then
    echo "#$child was already handed over; leaving it alone"
    continue
  fi
  gh issue edit "$child" --repo "$REPO" \
    --remove-label "$REFINE_LABEL" --remove-label "$IMPLEMENT_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$child" --repo "$REPO" --add-label "$REFINED_LABEL" >/dev/null
  gh issue edit "$child" --repo "$REPO" --add-label "$IMPLEMENT_LABEL" >/dev/null
  echo "#$child handed to implement"
done
