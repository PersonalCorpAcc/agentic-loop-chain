#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/redispatch-implement.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Send an implement that died in an outage back through the router as its next attempt.
#
# Environment: GH_TOKEN, REPO, REF (the repository's default branch: a dispatch runs the
# workflow file at the ref it names, FR-025), ISSUE_NUMBER, NEXT (this attempt's number),
# RUN_ID (this run), PAUSE_SECONDS (default 30).

set -euo pipefail
# The provider recovers in seconds, so pause before re-entering rather than dispatching back
# into the same outage. The router's own classify and authorize jobs add more.
sleep "${PAUSE_SECONDS:-30}"
# `retry-of` names this run, which is still in progress while it dispatches: without it the
# router's in-flight check saw this run as an implement already running for the issue and
# dropped every retry as a duplicate (loopscope #164, 21/11/2026).
gh workflow run work-router.yml --repo "$REPO" --ref "$REF" \
  -f operation=implement -f issue-number="$ISSUE_NUMBER" -f attempts_so_far="$NEXT" \
  -f retry-of="$RUN_ID"
echo "Re-dispatched implement for #$ISSUE_NUMBER as attempt $NEXT."
