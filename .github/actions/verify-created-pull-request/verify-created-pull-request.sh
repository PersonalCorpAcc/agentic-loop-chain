#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/verify-created-pull-request/verify-created-pull-request.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The pull request the framework says it made, checked against what it should be (FR-061).
#
# Everything here is a way for a run to be green and wrong. The framework appends its own
# closing keyword unless told not to; it salts the branch name unless told not to; and with
# signed commits on it recreates the branch at the base tip and replays the agent's files
# from the branch point, which under a chain reverts the base. Each of those is switched off
# in the worker's frontmatter, and each switch is one key in a configuration the compiler
# returns *empty* on any parse failure while still succeeding. So the switches are asserted
# again here, against the pull request that actually exists.
#
# The fourth failure FR-061 names, a fallback issue, is prevented rather than detected: the
# compile script refuses a lock whose handler configuration does not carry
# `fallback_as_issue: false`, and the run-time signature of such an issue is a title and
# labels gh-aw does not document. A check that cannot fire is worse than one that cannot be
# reached, so this file does not pretend to make it.

set -euo pipefail

: "${REPO:?verify-created-pull-request: REPO is required}"
: "${PR_NUMBER:?verify-created-pull-request: PR_NUMBER is required}"

problems=()

pr="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName,headRefOid,closingIssuesReferences 2>/dev/null || true)"
if [ -z "$pr" ]; then
  echo "::error::The run reported pull request #${PR_NUMBER}, and the forge has no such pull request in ${REPO}."
  exit 1
fi

head_branch="$(jq -r '.headRefName' <<<"$pr")"
head_sha="$(jq -r '.headRefOid' <<<"$pr")"

# 1. A closing reference means the forge will close the issue at the first merge, whatever
#    the profile says about which stage ends a change's life (FR-030).
closing="$(jq -r '[.closingIssuesReferences[].number] | join(", ")' <<<"$pr")"
if [ -n "$closing" ]; then
  problems+=("it closes issue(s) ${closing}: the link action neutralises closing keywords and writes a marker instead, so a surviving reference means the body reached the forge unneutralised")
fi

# 2. A branch this loop did not name is a branch nothing downstream can recognise, and
#    `preserve-branch-name` is what stops the framework salting it.
if [ -n "${BRANCH_PATTERN:-}" ] && ! printf '%s' "$head_branch" | grep -qE "${BRANCH_PATTERN}"; then
  problems+=("its head branch '${head_branch}' does not match the template this loop names branches with ('${BRANCH_PATTERN}')")
fi

# 3. The base rewrite. The fault is the framework recreating the branch at the *base* and
#    replaying the agent's files over it, which silently reverts everything the base had and
#    the agent never saw (research R11). The question that detects it is "was this branch
#    built on the commit we told the agent to cut from", and it is asked directly: the branch
#    point's tip is recorded before the agent runs and must be an ancestor of the head.
#
#    It used to be asked the other way round -- fail if the *base* tip is an ancestor of the
#    head -- on the reasoning that under a chain the head descends from the branch point and
#    so cannot descend from the base. That reasoning does not survive contact with a chain in
#    its ordinary state: `dev` is normally behind `main`, work is cut from `main`, and an
#    ancestor of `main` is an ancestor of everything cut from it. The check therefore failed
#    every correct run. The canary proved it on 17/09/2026 -- head 1edaf4f's parent was
#    main's tip, exactly where the profile says to cut, and the pull request was refused.
if [ -n "${BRANCH_POINT_TIP:-}" ]; then
  status="$(gh api "repos/${REPO}/compare/${BRANCH_POINT_TIP}...${head_sha}" --jq '.status' 2>/dev/null || echo unknown)"
  case "$status" in
    ahead | identical)
      : # The head contains the branch point, which is the shape a correct run produces.
      ;;
    unknown)
      echo "::warning::Could not compare ${BRANCH_POINT_TIP} with ${head_sha}, so a base rewrite cannot be ruled out for #${PR_NUMBER}."
      ;;
    *)
      problems+=("the branch point recorded before the agent ran (${BRANCH_POINT_TIP}) is not an ancestor of the head (${head_sha}): this branch was not cut where this loop cuts branches, which is what a branch recreated at the base looks like")
      ;;
  esac
fi

if [ "${#problems[@]}" -gt 0 ]; then
  for problem in "${problems[@]}"; do
    echo "::error::Pull request #${PR_NUMBER} is not the pull request this loop asked for: ${problem}."
  done
  exit 1
fi

echo "Pull request #${PR_NUMBER} is on branch ${head_branch}, closes nothing by keyword, and does not rewrite its base."
