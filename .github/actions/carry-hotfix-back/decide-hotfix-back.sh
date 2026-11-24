#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/carry-hotfix-back/decide-hotfix-back.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is this merge a hotfix on a release branch that must be carried back to the trunk? (FR-055)
#
# Writes `carry=true` and `issue=<n>` to GITHUB_OUTPUT when it is, and `carry=false` otherwise.
# The router's hotfix-back job runs this after a merge on a stage.
#
# Environment: GH_TOKEN, REPO, BASE_REF (the branch the pull request merged into), PR,
# LINKED (the issue the router already resolved, may be empty), HOTFIX_LABEL, TRUNK,
# RELEASE_PATTERN (an anchored expression; empty when the repository cuts no release branches),
# GITHUB_OUTPUT.

set -euo pipefail

# shellcheck source=SCRIPTDIR/../resolve-pr-issue/resolve-pr-issue.sh
. "$(dirname "${BASH_SOURCE[0]}")/../resolve-pr-issue/resolve-pr-issue.sh"

echo "carry=false" >> "$GITHUB_OUTPUT"

# A repository that cuts no release branches has no pattern at all: the optional token takes
# its own line with it, so this is read defensively.
if [ -z "${RELEASE_PATTERN:-}" ]; then
  echo "This repository cuts no release branches; nothing to carry back."
  exit 0
fi
if ! printf '%s' "$BASE_REF" | grep -qE "${RELEASE_PATTERN}"; then
  echo "${BASE_REF} is not a release branch; the trunk is where this change already is."
  exit 0
fi

issue="${LINKED:-}"
[ -n "$issue" ] || issue="$(pr_issue "$PR")"
if [ -z "$issue" ]; then
  echo "::notice::PR #${PR} merged into ${BASE_REF} but belongs to no issue this loop knows; nothing to carry back."
  exit 0
fi

# Without the label this is ordinary work on a release branch, and FR-055 says the route only
# records which branch it reached -- which stage-merge has already done.
if ! gh issue view "$issue" --repo "$REPO" --json labels --jq '[.labels[].name]' |
  jq -e --arg name "$HOTFIX_LABEL" 'index($name)' >/dev/null 2>&1; then
  echo "Issue #${issue} does not carry ${HOTFIX_LABEL}; ${BASE_REF} is where this change belongs."
  exit 0
fi

{
  echo "carry=true"
  echo "issue=${issue}"
} >> "$GITHUB_OUTPUT"
echo "Issue #${issue} is a hotfix on ${BASE_REF}; carrying it back to ${TRUNK}."
