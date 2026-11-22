#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/templates/canary/check-peers.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The dead-man's switch (feature 007 APP-03). A canary whose cycle has stopped cannot say so:
# the schedule was off, the workflow was never installed, Actions were disabled -- and the
# router went on reporting green for two months while nothing was carried (HANDOFF 20/11/2026).
# So each canary checks the others after its own cycle: every peer must have a successful
# cycle no older than MAX_AGE_HOURS. Three canaries would all have to stop at once for the
# silence to go unnoticed.
#
# Writes one line per quiet peer to stdout and exits 1 when there is any; the caller keeps one
# issue about it. Reads only, with a token that can see the peers' Actions runs.

set -euo pipefail

: "${PEERS:?check-peers: PEERS is required, as owner/name,owner/name}"
: "${GH_TOKEN:?check-peers: GH_TOKEN is required}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"
WORKFLOW_FILE="${WORKFLOW_FILE:-canary-cycle.yml}"
NOW="${NOW:-$(date -u +%s)}"

quiet=0
IFS=',' read -r -a peers <<<"$PEERS"
for peer in "${peers[@]}"; do
  [ -n "$peer" ] || continue
  if ! last=$(gh api "repos/${peer}/actions/workflows/${WORKFLOW_FILE}/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].created_at // ""' 2>&1); then
    echo "${peer}: its cycle cannot be read ($(printf '%s' "$last" | head -n 1)); the workflow may be missing, or this token cannot see it."
    quiet=1
    continue
  fi
  if [ -z "$last" ]; then
    echo "${peer}: no successful cycle has ever run."
    quiet=1
    continue
  fi
  age_hours=$(( (NOW - $(date -u -d "$last" +%s)) / 3600 ))
  if [ "$age_hours" -ge "$MAX_AGE_HOURS" ]; then
    echo "${peer}: the last successful cycle was ${age_hours} hours ago (${last})."
    quiet=1
  fi
done
exit "$quiet"
