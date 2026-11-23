#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/classify-incomplete.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Why a worker's run ended without an outcome, as far as the run can tell (FR-087, FR-113).
# Shared by implement and refine, whose incomplete jobs decide what to do with the answer.
#
# Writes to GITHUB_OUTPUT:
#   minutes   how long the agent job ran, or -1 when it cannot be read (treat as long)
#   billing   true when the provider refused the account (no credit, bad key): never retried
#   transient true when the run ended on a temporary answer from the provider's edge
#   kind      credits  -- the repository's daily AI-credit allowance stopped the agent starting
#             outage   -- the agent ran briefly and was not refused: what a provider outage
#                         looks like, and worth repeating. Also a run of any length whose
#                         last words are the provider's transient answer (see TRANSIENT below)
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
# The job finished seconds ago and its log is archived a little later, so an empty read is
# asked again before it is taken as "nothing said".
log="$(mktemp)"
if [ -n "${job_id:-}" ]; then
  for wait in 0 10 20 30; do
    sleep "$wait"
    gh api "${log_flags[@]}" "repos/$REPO/actions/jobs/${job_id}/logs" > "$log" 2>/dev/null || true
    [ -s "$log" ] && break
  done
fi
tail -n "${TAIL_LINES:-200}" "$log" > "$log.tail"

# A temporary answer from the provider's edge, not from the provider: a Cloudflare challenge
# page ("Just a moment..."), an overloaded or 5xx status. The CLI can wrap it in its own words
# -- loopscope #363, 22/11/2026: after fifteen minutes of good calls the claude CLI reported
# "Failed to authenticate. API Error: Just a moment..." with `authentication_failed`, which
# the refusal signature matches -- so this is asked first, and only of the log's last lines,
# where the run's ending is, rather than of tool output that quotes anything at all.
TRANSIENT='Just a moment\.\.\.|cf-chl|challenge-platform|overloaded_error|"api_error_status":5[0-9][0-9]|50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)'
transient=false
if grep -qE "$TRANSIENT" "$log.tail"; then transient=true; fi

billing=false
if [ "$transient" = false ] && [ -n "${REFUSAL_SIGNATURE:-}" ] && grep -qiE "${REFUSAL_SIGNATURE}" "$log"; then
  billing=true
fi
rm -f "$log" "$log.tail"

if [ "${CREDITS_EXCEEDED:-false}" = true ]; then
  kind=credits
elif [ "$transient" = true ]; then
  kind=outage
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
  echo "transient=$transient"
  echo "kind=$kind"
} >> "$GITHUB_OUTPUT"
echo "agent job ran for ${minutes}m; transient=${transient}; billing=${billing}; credits exceeded=${CREDITS_EXCEEDED:-false}; kind=${kind}"
