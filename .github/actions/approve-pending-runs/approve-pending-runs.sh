#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/approve-pending-runs/approve-pending-runs.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Approve every workflow run waiting for approval on a bot pull request's branch (the router's
# bot-approve job).
#
# Environment: GH_TOKEN, REPO, BRANCH. Output: approved (how many runs were waiting).

set -euo pipefail

mapfile -t run_ids < <(
  gh api "repos/$REPO/actions/runs?status=action_required&branch=$BRANCH" \
    --jq '.workflow_runs[].id'
)

echo "approved=${#run_ids[@]}" >> "$GITHUB_OUTPUT"

if [ "${#run_ids[@]}" -eq 0 ]; then
  echo "No runs awaiting approval on branch $BRANCH"
  exit 0
fi

for run_id in "${run_ids[@]}"; do
  # Only a run id. On a 5xx gh can print the error body where the answer goes, and approving
  # "{" is a 404 that ends the job (chain canary, 21/11/2026).
  case "$run_id" in '' | *[!0-9]*) echo "::warning::Skipping '$run_id': not a run id"; continue ;; esac
  echo "Approving run $run_id"
  gh api "repos/$REPO/actions/runs/$run_id/approve" --method POST
done
