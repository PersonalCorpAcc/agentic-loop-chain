#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/read-implement-outcome/read-implement-outcome.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Read why an implement run opened no pull request (feature 007 WF-12, FR-073).
#
# The kit ends its report with one machine-readable line:
#
#   outcome=<succeeded|failed|refused> phase=<...> change=<id|none> commits=<n> reason=<token|->
#
# The agent is told to begin `report_incomplete`'s reason with that line verbatim, and that item
# travels in the agent artefact, which is a structured file, not a log. So the artefact is read
# first, the way refine's validate_output reads its own. The archived agent-job log is the
# fallback, for an agent that printed the line and did not repeat it: that read waits on GitHub
# archiving the log, which answers 404 for a while after the job ends (loopscope, 20/11/2026).
#
# The pattern demands real values and the last match wins, because the prompt shows the line's
# shape and the prompt is printed into the same log: `phase=<...>` does not match `phase=[a-z]+`.
#
# Reads:
#   OUTPUT_FILE         agent_output.json from the agent artefact; empty when it was not found
#   REPO, RUN_ID        for the log fallback, with GH_TOKEN
#   LOG_ATTEMPTS        reads of the log before giving up (default 8)
#   LOG_RETRY_SECONDS   wait between them (default 15)
# Writes outcome, phase, reason, declined and source to $GITHUB_OUTPUT.
set -euo pipefail

PATTERN='outcome=(succeeded|failed|refused) phase=[a-z]+ change=[^ ]+ commits=[0-9]+ reason=[a-z-]+'

line=""
source=""
outcome=""
phase=""
why=""

if [ -n "${OUTPUT_FILE:-}" ] && [ -f "$OUTPUT_FILE" ]; then
  incomplete="$(jq -r '[.items[]? | select(.type == "report_incomplete") | .reason // ""] | last // empty' "$OUTPUT_FILE")"
  noop="$(jq -r '[.items[]? | select(.type == "noop") | .message // ""] | last // empty' "$OUTPUT_FILE")"
  has_incomplete="$(jq '[.items[]? | select(.type == "report_incomplete")] | length > 0' "$OUTPUT_FILE")"
  has_noop="$(jq '[.items[]? | select(.type == "noop")] | length > 0' "$OUTPUT_FILE")"
  if [ "$has_incomplete" = true ]; then
    source=agent-output
    line="$(printf '%s\n' "$incomplete" | grep -oE "$PATTERN" | tail -n 1 || true)"
    if [ -z "$line" ]; then
      # Stopped by something other than the pipeline -- the codebase would not build, a tool was
      # missing -- so there is no line, and the agent's own words are the reason.
      outcome=incomplete
      phase=none
      why=reported-incomplete
      echo "The agent reported the run incomplete: ${incomplete}"
    fi
  elif [ "$has_noop" = true ]; then
    # The agent found the work already done. Nothing changed, so a person confirms and closes it;
    # left labelled implement it would only be picked up again.
    source=agent-output
    outcome=noop
    phase=none
    why=already-done
    echo "The agent found nothing to change: ${noop}"
  fi
else
  echo "No agent output to read; falling back to the agent job's log."
fi

if [ -z "$source" ]; then
  source=log
  # A job log carries terminal colour codes, and a recent gh refuses to print such a response
  # without --allow-escape-sequences: every read failed with that, which read as "not archived
  # yet" and left no outcome at all (loopscope #293, 22/11/2026). An older gh has no such flag.
  log_flags=()
  if gh api --help 2>&1 | grep -q -- '--allow-escape-sequences'; then log_flags=(--allow-escape-sequences); fi
  # A called workflow shares the caller's run id, so the agent job is in this run.
  job_id="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" \
    --jq '[.jobs[] | select(.name | endswith("agent"))] | last | .id // empty')"
  if [ -n "${job_id:-}" ]; then
    attempts="${LOG_ATTEMPTS:-8}"
    for attempt in $(seq 1 "$attempts"); do
      if log="$(gh api "${log_flags[@]}" "repos/$REPO/actions/jobs/${job_id}/logs" 2>&1)"; then
        line="$(printf '%s' "$log" | grep -oE "$PATTERN" | tail -n 1 || true)"
        break
      fi
      echo "attempt ${attempt}: the agent job's log is not readable yet: $(printf '%s' "$log" | head -n 1)"
      [ "$attempt" -lt "$attempts" ] && sleep "${LOG_RETRY_SECONDS:-15}"
    done
  else
    echo "No agent job was found in run ${RUN_ID}."
  fi
fi

declined=true
if [ -n "$line" ]; then
  outcome="${line#outcome=}"
  outcome="${outcome%% *}"
  phase="${line#*phase=}"
  phase="${phase%% *}"
  why="${line##*reason=}"
  [ "$outcome" = succeeded ] && declined=false
elif [ -z "$outcome" ]; then
  # No pull request and no readable outcome is never a quiet success: the work did not happen,
  # so a person is told, exactly as for a refusal.
  outcome=unknown
  phase=none
  why="no outcome line could be read"
fi

{
  echo "outcome=${outcome}"
  echo "phase=${phase}"
  echo "reason=${why}"
  echo "declined=${declined}"
  echo "source=${source}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "The pipeline's outcome (from the ${source}): ${line:-<no line>} -> ${outcome}"
