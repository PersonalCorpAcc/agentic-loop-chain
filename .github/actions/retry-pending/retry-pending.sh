#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/retry-pending.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Re-dispatch refine and implement runs that ended for a reason that passes (feature 007,
# FR-113). The hourly reconcile belt runs this.
#
# A worker whose run ends without an outcome for a transient reason -- the repository's daily
# AI-credit allowance, or a provider outage short enough to look like one -- keeps its route
# label and says so with a marked comment:
#
#   <!-- agent-retry-pending: <route> <credits|outage> -->
#
# and nothing else ever looked at it. Only label events start these routes, so the issue sat
# with a comment promising a retry that never came (loopscope #265 and #268, 21/11/2026, twelve
# hours). This is the "later" in that comment.
#
# An issue is retried when, and only when:
#   - it is open, carries the route's label, and carries none of the working, review or hold
#     labels (a run holds it, a person has it, or a person stopped it);
#   - its newest comment is that marker, so anything since -- an outcome, a person -- stops it;
#   - the marker is at least RETRY_AFTER_MINUTES old;
#   - no router run for the issue is in flight.
# Outage retries are capped at RETRY_ATTEMPTS, after which the issue goes to a person with one
# comment saying so (which, being newer than the marker, ends the retries). A credits marker is
# not counted: no agent ran, nothing was spent, and the day's allowance resets on its own.
#
# Reads: REPO, GH_TOKEN, DEFAULT_BRANCH, WORKING_LABEL, REVIEW_LABEL, HOLD_LABEL,
#        RETRY_AFTER_MINUTES, RETRY_ATTEMPTS; NOW (epoch seconds) for tests.
set -euo pipefail

now="${NOW:-$(date -u +%s)}"

# A pre-filter like the router's others (decision D4): run titles are presentation. The
# worker's own eligibility and concurrency group are what make a duplicate harmless; this only
# avoids starting one.
run_in_flight() {
  local issue="$1" status live
  for status in queued in_progress waiting pending; do
    live=$(gh api "repos/$REPO/actions/workflows/work-router.yml/runs?status=$status&per_page=100" \
      --jq "[.workflow_runs[] | select((.display_title | startswith(\"Working (\")) and ((.display_title | endswith(\"(#${issue})\")) or (.display_title | endswith(\": #${issue}\"))))] | length" 2>/dev/null || echo 1)
    [ "${live:-1}" -eq 0 ] || return 0
  done
  return 1
}

retry_route() {
  local route="$1" issue newest at body age outages
  gh issue list --repo "$REPO" --label "$route" --state open --limit 100 --json number,labels \
    --jq ".[] | select([.labels[].name] | (index(\"${WORKING_LABEL}\") or index(\"${REVIEW_LABEL}\") or index(\"${HOLD_LABEL}\")) | not) | .number" |
    while IFS= read -r issue; do
      case "$issue" in '' | *[!0-9]*) continue ;; esac

      # Comments come oldest first, page by page, so the last line is the newest.
      newest="$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --paginate \
        --jq '.[] | [.created_at, .body] | @json' 2>/dev/null | tail -n 1)"
      [ -n "$newest" ] || continue
      body="$(jq -r '.[1]' <<<"$newest")"
      case "$body" in *"<!-- agent-retry-pending: ${route} "*) ;; *) continue ;; esac

      at="$(jq -r '.[0]' <<<"$newest")"
      age=$(( (now - $(date -u -d "$at" +%s)) / 60 ))
      if [ "$age" -lt "$RETRY_AFTER_MINUTES" ]; then
        echo "#$issue: ${route} retry pending, ${age}m of ${RETRY_AFTER_MINUTES}m waited."
        continue
      fi

      outages="$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --paginate \
        --jq ".[] | select(.body | contains(\"<!-- agent-retry-pending: ${route} outage -->\")) | .id" 2>/dev/null | grep -c . || true)"
      if [ "${outages:-0}" -ge "$RETRY_ATTEMPTS" ]; then
        echo "#$issue: ${route} ended without an outcome ${outages} times; handing it to a person."
        gh issue edit "$issue" --repo "$REPO" --add-label "$REVIEW_LABEL" >/dev/null 2>&1 || true
        gh issue comment "$issue" --repo "$REPO" --body "Automated ${route} ended without an outcome ${outages} times in a row, each time early enough to look like a provider outage, so it is no longer retried. The issue now carries \`${REVIEW_LABEL}\`; remove it and re-add \`${route}\` to try again." >/dev/null
        continue
      fi
      if run_in_flight "$issue"; then
        echo "#$issue: a run for it is already in flight."
        continue
      fi

      echo "#$issue: retrying ${route} (${outages} outage retr$([ "${outages:-0}" -eq 1 ] && echo y || echo ies) so far)."
      gh api "repos/$REPO/actions/workflows/work-router.yml/dispatches" --method POST \
        -f ref="$DEFAULT_BRANCH" -f "inputs[operation]=${route}" -f "inputs[issue-number]=${issue}" ||
        echo "::warning::Could not retry ${route} on #${issue}; the next sweep will try again."
    done
}

retry_route refine
retry_route implement
