#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/check-merge-preconditions/check-merge-preconditions.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# What the forge says about this pull request before anything tries to merge it (FR-068).
#
# A merge the forge will refuse is not an error to retry: it is a pull request that needs a
# person, and a red run says neither which pull request nor what to do about it. So the
# state is read first, and a refusal becomes a review with a sentence rather than an attempt
# with a stack trace.
#
# Writes `mergeable=`, `deferrable=` and `refusal=` to $GITHUB_OUTPUT. The caller decides
# what to do with a false, because the gate and the output applier label different things.
#
# `deferrable` is the third answer, and it exists because `BLOCKED` is not a refusal aimed at
# us (FR-080). The merge state is a property of the pull request against its base, not of the
# caller asking: a repository rule holding a pull request reports `BLOCKED` to everybody,
# including an actor the ruleset would let through, and there is no caller-aware read to ask
# instead -- `GET /repos/{owner}/{repo}/rules/branches/{branch}` returns the same rules to a
# bypassing App, to the workflow token and to an administrator (D8, 18/09/2026). So `BLOCKED`
# means "a rule is holding this, and the rule may yet be satisfied": the caller arms
# auto-merge and GitHub performs the merge when the required review or check arrives, which
# is GitHub's own documented pattern for a bot landing its own pull requests (D9). Everything
# else stays a refusal, because every other state is a fact about the pull request rather
# than about a rule somebody may satisfy.

set -euo pipefail

: "${REPO:?check-merge-preconditions: REPO is required}"
: "${PR_NUMBER:?check-merge-preconditions: PR_NUMBER is required}"
: "${MERGE_METHOD:?check-merge-preconditions: MERGE_METHOD is required}"

case "$PR_NUMBER" in
  '' | *[!0-9]*)
    echo "::error::check-merge-preconditions: '${PR_NUMBER}' is not a pull request number." >&2
    exit 1
    ;;
esac

case "$MERGE_METHOD" in
  squash | merge | rebase) ;;
  *)
    echo "::error::check-merge-preconditions: '${MERGE_METHOD}' is not a merge method. The profile decides this, and it is one of squash, merge or rebase." >&2
    exit 1
    ;;
esac

refuse() {
  {
    echo "mergeable=false"
    echo "deferrable=false"
    echo "refusal=$1"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  echo "PR #${PR_NUMBER} will not be merged: $1"
  exit 0
}

# Not now, but not a refusal either: a rule is holding it and the rule can still be satisfied.
defer() {
  {
    echo "mergeable=false"
    echo "deferrable=true"
    echo "refusal=$1"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  echo "PR #${PR_NUMBER} is not mergeable yet: $1"
  exit 0
}

# GitHub computes mergeability on demand, and the first read of a pull request nobody has
# opened recently answers UNKNOWN while it works the answer out in the background. Asking
# once and believing the answer is how "not conflicting" is reported for exactly the pull
# requests that are: the router learned this twice in production.
state="UNKNOWN"
for _ in 1 2 3 4 5 6; do
  state="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo UNKNOWN)"
  [ "$state" = "UNKNOWN" ] || break
  sleep 5
done

case "$state" in
  DIRTY)
    refuse "it conflicts with its base branch, and a conflict the gate could not resolve is a person's to resolve."
    ;;
  DRAFT)
    refuse "it is a draft, and the forge refuses to merge one."
    ;;
  BLOCKED)
    # The wording matters: this is what a person reads on the pull request, and "the gate
    # refused" would be untrue. A required review that a person has not given yet is the
    # repository working as its owner configured it.
    defer "a repository rule is holding it -- a required review or a required check is outstanding. The gate marks it ready and the forge merges it when the rule is satisfied; it is never merged past a rule."
    ;;
  BEHIND)
    refuse "the base has moved and this repository requires branches to be up to date. Under a chain every branch is structurally behind its base and nothing here rebases to catch up, so that setting belongs off on the stages."
    ;;
  UNKNOWN)
    refuse "the forge would not say whether it can be merged, even after polling. Nothing is merged on an unknown state."
    ;;
esac

# `rebaseable` is a REST field, and it is a precondition only under rebase: under squash or
# merge the forge builds one commit and an unreplayable history is not in its way.
if [ "$MERGE_METHOD" = "rebase" ]; then
  rebaseable="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.rebaseable // "null"' 2>/dev/null || echo null)"
  if [ "$rebaseable" = "false" ]; then
    refuse "the forge cannot replay its commits onto the base, and this repository merges by rebase."
  fi
fi

{
  echo "mergeable=true"
  echo "deferrable=false"
  echo "refusal="
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
echo "PR #${PR_NUMBER} may be merged: the forge reports ${state}."
