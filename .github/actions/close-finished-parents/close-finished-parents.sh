#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/close-finished-parents/close-finished-parents.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Close every open parent issue whose children are all closed (FR-146).
#
# Refine splits a large issue into children and the children are built, merged and closed one by
# one, but nothing closed the parent: GitHub does not close a parent when its last sub-issue
# closes, and the closing paths (a pull request's closing keyword, stage-merge's carried issues)
# only ever see the child. Loopscope carried four finished epics for days (#138, #139, #140, #159,
# found 24/11/2026). This runs in the reconcile belt, so it is level-triggered: a parent is closed
# whenever the belt finds it finished, whatever branching strategy closed the children.
#
# A parent on hold is left alone. Each sub-issue list is read again before closing, so a summary
# that lags behind a just-added child does not close a parent with open work.
#
# Environment: GH_TOKEN, REPO, HOLD_LABEL.

set -euo pipefail

parents=$(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" --jq \
  ".[] | select(.pull_request == null)
       | select((.sub_issues_summary.total // 0) > 0 and .sub_issues_summary.completed == .sub_issues_summary.total)
       | select([.labels[].name] | index(\"$HOLD_LABEL\") | not)
       | .number" 2>/dev/null) || {
  echo "::warning::Could not list open issues; no parent was closed."
  exit 0
}

while IFS= read -r parent; do
  [ -n "$parent" ] || continue
  if ! children=$(gh api --paginate "repos/$REPO/issues/$parent/sub_issues?per_page=100" --jq '.[] | "#\(.number) \(.state)"' 2>/dev/null); then
    echo "::warning::Could not read the children of #$parent; left open."
    continue
  fi
  if [ -z "$children" ] || grep -qv ' closed$' <<<"$children"; then
    echo "#$parent still has open children; left open."
    continue
  fi
  list=$(awk '{print $1}' <<<"$children" | paste -sd ',' -)
  list="${list//,/, }"
  if gh issue close "$parent" --repo "$REPO" --reason completed \
    --comment "Every child of this issue is closed (${list}), so it is closed too." >/dev/null; then
    echo "#$parent closed: every child is closed (${list})."
  else
    echo "::warning::#$parent has every child closed but could not be closed."
  fi
done <<<"$parents"
