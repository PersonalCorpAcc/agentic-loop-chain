#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/decide-implement-retry.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is a failed implement worth repeating? (FR-053, FR-113) Reads what classify-incomplete.sh
# found. An outage is retried at once, up to the park attempt; the daily AI-credit allowance is
# deferred to the hourly sweep, because no agent ran; everything else, a billing refusal
# included, is a person's.
#
# Environment: KIND (outage, credits, billing or final), BILLING (true or false), MINUTES,
# ATTEMPTS (attempts so far), PARK_AT.
# Outputs: retry, deferred, billing, next (this attempt's number), minutes.

set -euo pipefail
retry=false
deferred=false
if [ "$KIND" = outage ] && [ "$ATTEMPTS" -lt "$PARK_AT" ]; then retry=true; fi
if [ "$KIND" = credits ]; then deferred=true; fi
{
  echo "retry=$retry"
  echo "deferred=$deferred"
  echo "billing=$BILLING"
  echo "next=$((ATTEMPTS + 1))"
  echo "minutes=$MINUTES"
} >> "$GITHUB_OUTPUT"
echo "kind=${KIND}; attempts so far ${ATTEMPTS}; retry=${retry}; deferred=${deferred}"
