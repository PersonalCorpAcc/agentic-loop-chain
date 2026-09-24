#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/apply-agent-bundle/apply-bundle.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
set -euo pipefail

BUNDLE_FILE=$1
TARGET_BRANCH=$2
BASE_BRANCH=${3:-}

fail() {
  echo "::error::$1"
  exit 1
}

# The credential belongs to the git commands in this file and to nothing else (FR-067).
# `git config --global` would leave it in the runner's home directory for every later step,
# and a token in a remote URL is written into .git/config and printed by anything that
# reports the remote. GIT_CONFIG_COUNT carries it in this process's environment instead,
# where it reaches git and not the command line: an argument is readable by every other
# process on the runner.
if [ -n "${GIT_TOKEN:-}" ]; then
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=http.extraheader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GIT_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
fi

[ -f "$BUNDLE_FILE" ] || fail "Git bundle not found: $BUNDLE_FILE"
git check-ref-format --branch "$TARGET_BRANCH" >/dev/null || fail "Invalid target branch: $TARGET_BRANCH"

if [ -n "$BASE_BRANCH" ]; then
  git check-ref-format --branch "$BASE_BRANCH" >/dev/null || fail "Invalid base branch: $BASE_BRANCH"
fi

git bundle verify "$BUNDLE_FILE"
mapfile -t BUNDLE_HEADS < <(git bundle list-heads "$BUNDLE_FILE")
[ "${#BUNDLE_HEADS[@]}" -eq 1 ] || fail "Git bundle must expose exactly one ref"

read -r BUNDLE_TIP BUNDLE_REF <<< "${BUNDLE_HEADS[0]}"
if [ -z "$BUNDLE_TIP" ] || [ -z "$BUNDLE_REF" ]; then
  fail "Git bundle ref is invalid"
fi

if git ls-remote --exit-code --heads origin "refs/heads/$TARGET_BRANCH" >/dev/null; then
  git fetch --no-tags origin "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH"
  TARGET_TIP=$(git rev-parse "refs/remotes/origin/$TARGET_BRANCH")
else
  [ -n "$BASE_BRANCH" ] || fail "Target branch does not exist and no base branch was supplied"
  git fetch --no-tags origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH"
  TARGET_TIP=$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")
fi

git fetch --no-tags "$BUNDLE_FILE" "$BUNDLE_REF"
[ "$(git cat-file -t "$BUNDLE_TIP")" = commit ] || fail "Git bundle ref must point directly to a commit"
[ "$(git rev-parse FETCH_HEAD)" = "$BUNDLE_TIP" ] || fail "Fetched bundle commit did not match listed bundle ref"

git merge-base --is-ancestor "$TARGET_TIP" "$BUNDLE_TIP" || fail "Git bundle cannot fast-forward $TARGET_BRANCH"
git switch --detach "$TARGET_TIP"
git merge --ff-only "$BUNDLE_TIP"
git push origin "HEAD:refs/heads/$TARGET_BRANCH"
