#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/cut-release/commit-tag-push.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Commit the staged version bump, tag the release, and push both (FR-016, FR-067).
#
# Environment: NEW_VERSION, GH_TOKEN, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GITHUB_SERVER_URL,
# GITHUB_REPOSITORY. REMOTE_URL overrides the remote, which is otherwise this repository on
# this forge; a test points it at a local bare repository.

set -euo pipefail
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"

# The checkout persists no credentials, so GH_TOKEN reaches `gh` and not git, and the push fails
# with "could not read Username" after the notes have been written. Carried per command through
# git's own environment rather than written into the remote URL, which .git/config would keep
# and every later step would inherit (FR-067).
host="${GITHUB_SERVER_URL#https://}"
git remote set-url origin "${REMOTE_URL:-https://${host}/${GITHUB_REPOSITORY}.git}"
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=http.extraheader
GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

if ! git diff --cached --quiet; then
  git commit -m "chore(release): v${NEW_VERSION}"
  # The version commit lands on the default branch, which an adopter's rules may protect
  # against exactly this. A refusal here is the forge working, and it says which rule it was; a
  # repository whose version source is the tag stages nothing and never reaches this line.
  git push
fi
# The tag just made, rather than every tag in the clone: --tags would carry anything a previous
# step happened to fetch.
git tag "v${NEW_VERSION}"
git push origin "v${NEW_VERSION}"
echo "Tagged v${NEW_VERSION} and pushed."
