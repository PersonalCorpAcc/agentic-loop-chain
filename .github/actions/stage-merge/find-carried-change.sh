#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/stage-merge/find-carried-change.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The change a pull request that closed on a stage carries (the router's stage-merge job,
# FR-030, FR-031, FR-051).
#
# Environment: GH_TOKEN, REPO, PR, LINKED (the classifier's answer, may be empty), BASE_REF,
# MERGED_STAGE_LABEL (with a `{stage}` placeholder).
# Outputs: issues (one per line), issue (the first, or LINKED), issue_count, promotion (true or
# empty), stage_label.

set -euo pipefail
# The classifier resolved this already for the routes that need it; this is the same rule when
# it did not (FR-030).
# shellcheck source=SCRIPTDIR/../resolve-pr-issue/resolve-pr-issue.sh
. "$(dirname "${BASH_SOURCE[0]}")/../resolve-pr-issue/resolve-pr-issue.sh"

# Every issue this pull request carries, not just the first. Under `env-promotion` the head is a
# snapshot of the stage below, so one promotion carries whatever merged there since the last one
# and every one of those issues reached this stage when it merged. Labelling only the first would
# leave the rest sitting on a stage they had left, and would never close them (FR-031, FR-051).
#
# Every other strategy carries exactly one, so `issues` is that one and the scalar `issue` below
# is the same value: the readers that want a single number -- the outcome line, the comment
# text -- keep reading one.
issues="$(pr_issues "$PR")"
[ -n "$issues" ] || issues="${LINKED:-}"
{
  echo "issues<<EOF_ISSUES"
  printf '%s\n' "$issues"
  echo "EOF_ISSUES"
} >> "$GITHUB_OUTPUT"

issue="${LINKED:-}"
[ -n "$issue" ] || issue="$(printf '%s' "$issues" | head -n1)"
echo "issue=${issue}" >> "$GITHUB_OUTPUT"
echo "issue_count=$(printf '%s\n' "$issues" | grep -c '[0-9]' || true)" >> "$GITHUB_OUTPUT"

# A promotion pull request carries the stage it was promoting into, which is what tells an
# unmerged close apart: a promotion that was rejected is a hold on the change, and a first-stage
# pull request that was closed is just a release.
promotion="$(gh pr view "$PR" --repo "$REPO" --json body --jq '.body // ""' |
  grep -oE '<!-- promotion-pr: [^:]+: [0-9]+ -->' | head -n1 || true)"
echo "promotion=${promotion:+true}" >> "$GITHUB_OUTPUT"

# `merged-{stage}` with the stage filled in. Built here because the expression language has no
# substitution: format() positions arguments, it does not replace a token inside a string.
echo "stage_label=${MERGED_STAGE_LABEL/'{stage}'/$BASE_REF}" >> "$GITHUB_OUTPUT"

if [ -z "$issue" ]; then
  echo "::notice::PR #${PR} closed on a stage but belongs to no issue this loop knows; nothing to move."
fi
