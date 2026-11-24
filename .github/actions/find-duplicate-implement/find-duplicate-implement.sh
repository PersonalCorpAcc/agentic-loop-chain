#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/find-duplicate-implement/find-duplicate-implement.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is an implement for this issue already under way, so this router run should not start
# another? Writes `has-open-pr=true|false` to GITHUB_OUTPUT.
#
# Three readings, in order: an older router run implementing the same issue, the pull request
# the App recorded for it if that is open, and an open bot pull request whose body closes it.
#
# Environment: GH_TOKEN, REPO, ISSUE_NUMBER, MARKER_PR and MARKER_SOURCE (the App's recorded
# linkage, may be empty), RETRY_OF (the run a retry was dispatched from, may be empty),
# GITHUB_RUN_ID, GITHUB_OUTPUT.

set -euo pipefail

# A refine-to-implement transition emits two label events (the implement label, then the
# worker re-adding its working label) and each one classifies to implement. The older router run
# wins: a younger run that finds an older live implement route for the same issue skips
# instead of queueing a duplicate worker. Only bot-actor titles are counted, so a human's
# "waiting for the working label" run can never block the real one.
#
# This is a pre-filter, not the guarantee. It reads run titles, which are presentation: they
# carry the issue's own text, they change when somebody edits `run-name`, and listing runs is
# eventually consistent, so two runs starting in the same second can both see nothing. What it
# buys is a skip before a runner starts, which nothing inside the worker can do.
#
# The guarantee is in the worker. `eligibility` runs while the concurrency group is held and
# asks the App's own record whether this issue already has an open pull request; a group
# permits one running job at a time, so by then the answer is true if it is going to be.
#
# Both run-name shapes, because there are two: an issue event renders
# `Working (Implement): <title> (#8)` and a dispatch renders `Working (Implement): #8`.
# Matching only the first made a dispatched implement invisible to this filter, and to
# itself, which produced two agent runs and two pull requests for issue #5 on 17/09/2026.
#
# Anchored to the end of the title rather than found anywhere in it: a title carries the
# issue's own text, so an issue named "Fix #80 handling" would read as a duplicate of #80.
#
# The run a retry comes from is still in progress while it dispatches -- its own incomplete
# job is the dispatcher -- so it is not a duplicate. Counting it dropped every outage retry
# (loopscope #164, 21/11/2026; FR-113).
for st in in_progress queued; do
  dupes=$(gh api "repos/$REPO/actions/workflows/work-router.yml/runs?status=$st&per_page=100" --jq "[.workflow_runs[]
      | select(.id < $GITHUB_RUN_ID and (.id | tostring) != \"${RETRY_OF:-}\")
      | select(
          ((.display_title | startswith(\"Working (Implement)\")) and ((.display_title | endswith(\"(#${ISSUE_NUMBER})\")) or (.display_title | endswith(\": #${ISSUE_NUMBER}\"))))
          or
          ((.display_title | contains(\"implement label on #${ISSUE_NUMBER} by\")) and (.display_title | endswith(\"[bot]\")))
        )
    ] | length" 2>/dev/null || echo 0)
  if [ "${dupes:-0}" -gt 0 ]; then
    echo "has-open-pr=true" >> "$GITHUB_OUTPUT"
    echo "::notice::An older router run is already implementing #$ISSUE_NUMBER; skipping the duplicate."
    exit 0
  fi
done

# Linkage first: the App records the pull request it opened, so the duplicate check is an
# exact lookup rather than a text search (FR-064). Only an OPEN pull request blocks; a merged
# or closed one means a re-implement is legitimate. A body-sourced answer is honoured here and
# said out loud: the cost of believing a marker somebody typed is one skipped implement on
# their own issue, and the cost of ignoring an uncorroborated one is a duplicate pull request.
if [ -n "${MARKER_PR:-}" ]; then
  state=$(gh pr view "$MARKER_PR" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo GONE)
  if [ "$state" = "OPEN" ]; then
    echo "has-open-pr=true" >> "$GITHUB_OUTPUT"
    echo "::notice::Issue #$ISSUE_NUMBER is linked (source: ${MARKER_SOURCE:-}) to open PR #$MARKER_PR. Skipping duplicate implement."
    exit 0
  fi
  echo "Linked PR #$MARKER_PR is $state; a fresh implement is allowed."
fi

existing=$(gh pr list --repo "$REPO" --state open --json number,author,body \
  --jq "[.[]
    | select(.author.login | startswith(\"app/\") or endswith(\"[bot]\"))
    | (.body | ascii_downcase) as \$body
    | select(\$body | contains(\"close #${ISSUE_NUMBER}\") or contains(\"closes #${ISSUE_NUMBER}\") or contains(\"closed #${ISSUE_NUMBER}\") or contains(\"fix #${ISSUE_NUMBER}\") or contains(\"fixes #${ISSUE_NUMBER}\") or contains(\"fixed #${ISSUE_NUMBER}\") or contains(\"resolve #${ISSUE_NUMBER}\") or contains(\"resolves #${ISSUE_NUMBER}\") or contains(\"resolved #${ISSUE_NUMBER}\"))
  ] | length")
if [ "$existing" -gt 0 ]; then
  echo "has-open-pr=true" >> "$GITHUB_OUTPUT"
  echo "::notice::Issue #$ISSUE_NUMBER already has an open bot PR. Skipping implement to prevent duplicates."
else
  echo "has-open-pr=false" >> "$GITHUB_OUTPUT"
fi
