#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/classify-incomplete.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Why a worker's run ended without an outcome, as far as the run can tell (FR-087, FR-113).
# Shared by implement and refine, whose incomplete jobs decide what to do with the answer.
#
# Writes to GITHUB_OUTPUT:
#   minutes   how long the agent job ran, or -1 when it cannot be read (treat as long)
#   billing   true when the provider refused the account (no credit, bad key): never retried
#   kind      credits  -- the repository's daily AI-credit allowance stopped the agent starting
#             outage   -- the agent ran briefly and was not refused: what a provider outage
#                         looks like, and worth repeating
#             billing  -- as above
#             final    -- anything else: a run that got this far will fail the same way again
#
# Reads: GH_TOKEN, REPO, RUN_ID, UNDER_MINUTES, REFUSAL_SIGNATURE, CREDITS_EXCEEDED.
set -euo pipefail

# The agent job belongs to this same run: a called workflow shares the caller's run id.
read -r job_id started finished <<<"$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" \
  --jq '[.jobs[] | select(.name | endswith("agent"))] | last // empty
        | "\(.id // "") \(.started_at // "") \(.completed_at // "")"' 2>/dev/null || true)"
minutes=-1
if [ -n "${started:-}" ] && [ -n "${finished:-}" ]; then
  minutes=$(( ( $(date -u -d "$finished" +%s) - $(date -u -d "$started" +%s) ) / 60 ))
fi

# A failure the account caused is not an outage, and retrying it cannot work. The duration
# cannot tell them apart -- a refused request fails in about a minute, which is exactly what a
# short outage looks like -- so this asks the log what the provider actually said, in that
# provider's own words. The framework's own `http_400_response_error` and
# `inference_access_error` outputs were both false for a 400 carrying `billing_error`.
# A job log carries terminal colour codes, and a recent gh refuses to print such a response
# without --allow-escape-sequences: every read failed with that, which read as "not archived
# yet" and left no outcome at all (loopscope #293, 22/11/2026). An older gh has no such flag.
log_flags=()
if gh api --help 2>&1 | grep -q -- '--allow-escape-sequences'; then log_flags=(--allow-escape-sequences); fi
billing=false
if [ -n "${job_id:-}" ] && [ -n "${REFUSAL_SIGNATURE:-}" ] &&
  gh api "${log_flags[@]}" "repos/$REPO/actions/jobs/${job_id}/logs" 2>/dev/null | grep -qiE "${REFUSAL_SIGNATURE}"; then
  billing=true
fi

if [ "${CREDITS_EXCEEDED:-false}" = true ]; then
  kind=credits
elif [ "$billing" = true ]; then
  kind=billing
elif [ "$minutes" -ge 0 ] && [ "$minutes" -lt "$UNDER_MINUTES" ]; then
  kind=outage
else
  kind=final
fi

{
  echo "minutes=$minutes"
  echo "billing=$billing"
  echo "kind=$kind"
} >> "$GITHUB_OUTPUT"
echo "agent job ran for ${minutes}m; billing=${billing}; credits exceeded=${CREDITS_EXCEEDED:-false}; kind=${kind}"
