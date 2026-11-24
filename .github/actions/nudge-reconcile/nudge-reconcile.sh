#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/nudge-reconcile/nudge-reconcile.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Start the reconcile belt from any router run when none has started for STALE_MINUTES (FR-138).
#
# The belt is the loop's only level-triggered recovery: orphaned implement work, pull requests
# with no gate, due retries, stale reservations. Its schedule asks for a run every hour, and
# GitHub delivered about three a day (loopscope, 22-23/11/2026: the hourly and the ten-minute
# crons alike), so in practice it ran only when a worker finished and started it. Every router
# run is a chance to look: a label, a comment, a CI run finishing, a pull request opening. This
# asks whether a belt has started recently, and starts one if not. It never starts a second:
# one waiting or running is enough, and the belt's concurrency group holds the rest.
#
# Reads: REPO, GH_TOKEN, DEFAULT_BRANCH, STALE_MINUTES (default 30); NOW (epoch seconds) for tests.
set -euo pipefail

now="${NOW:-$(date -u +%s)}"
stale="${STALE_MINUTES:-30}"
title="dispatch: reconcile-bot-pr-runs"

# The newest dispatched belt's status and start, whatever its state.
latest="$(gh api "repos/$REPO/actions/workflows/work-router.yml/runs?event=workflow_dispatch&per_page=100" \
  --jq "[.workflow_runs[] | select(.display_title == \"$title\")][0] // empty | [.status, .created_at] | @tsv" 2>/dev/null || true)"

if [ -n "$latest" ]; then
  IFS=$'\t' read -r status created <<<"$latest"
  if [ "$status" != completed ]; then
    echo "A reconcile belt is already $status; nothing to start."
    exit 0
  fi
  age=$(( (now - $(date -u -d "$created" +%s)) / 60 ))
  if [ "$age" -lt "$stale" ]; then
    echo "The last reconcile belt started ${age}m ago (under ${stale}m); nothing to start."
    exit 0
  fi
  echo "The last reconcile belt started ${age}m ago; starting one."
else
  echo "No reconcile belt on record; starting one."
fi

gh api "repos/$REPO/actions/workflows/work-router.yml/dispatches" --method POST \
  -f ref="$DEFAULT_BRANCH" -f "inputs[operation]=reconcile-bot-pr-runs" >/dev/null ||
  echo "::warning::Could not start the reconcile belt; the next router run will try again."
