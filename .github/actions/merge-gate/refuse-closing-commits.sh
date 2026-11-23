#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/refuse-closing-commits.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Under rebase every commit message lands on every stage, so a closing keyword in one closes
# the issue at the first stage (FR-030). Fails, naming the commits, when any carries one.
#
# Environment: GH_TOKEN, REPO, PR.

set -euo pipefail
offenders="$(gh api "repos/${REPO}/pulls/${PR}/commits" --paginate \
  --jq '.[] | select(.commit.message | test("(^|[^a-zA-Z])(close[sd]?|fixe?[sd]?|resolve[sd]?)[ :]*#[0-9]+"; "i")) | .sha[0:8] + " " + (.commit.message | split("\n")[0])')"
[ -z "$offenders" ] || {
  echo "::error::PR #${PR} merges by rebase and these commits carry a closing keyword, which would close the issue at the first stage they land on:"
  printf '%s\n' "$offenders" >&2
  exit 1
}
echo "No commit on PR #${PR} closes an issue by keyword."
