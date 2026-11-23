#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/stage-merge/carry-stage-down.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# A merge into a later stage breaks ancestry with the stages below it, so the run that caused it
# dispatches the sync-stages route rather than leaving it to the clock (FR-079, FR-086). Nothing
# is carried down from the first stage, or from a branch that is no stage.
#
# Environment: GH_TOKEN (the App's: a dispatch with the workflow token starts no run), REPO,
# MOVED (the stage that merged), STAGES (comma-separated, first stage first), DEFAULT_BRANCH.

set -euo pipefail
case ",${STAGES}," in
  *",${MOVED},"*) ;;
  *)
    echo "::notice::${MOVED} is not one of this repository's stages (${STAGES}); nothing to carry down."
    exit 0
    ;;
esac

# The first stage has nothing below it, and under trunk there is only one branch, so both answer
# here rather than dispatching a route that would find nothing.
first="${STAGES%%,*}"
if [ "$MOVED" = "$first" ]; then
  echo "${MOVED} is the first stage, so no stage is below it; nothing to carry down."
  exit 0
fi
echo "${MOVED} moved, so the stages below it may no longer descend from it; carrying down."
gh api "repos/$REPO/actions/workflows/work-router.yml/dispatches" \
  --method POST \
  -f ref="$DEFAULT_BRANCH" \
  -f "inputs[operation]=sync-stages"
