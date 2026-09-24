#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/update-changelog/update-changelog.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Prepend a changelog entry for a landed change and commit it onto the branch the caller is
# already on. No push: the caller pushes it with the rest of the promotion, so one branch,
# one push, one pull request. An action that pushed on its own could leave an entry on a
# branch whose promotion then failed to open (FR-031).
#
# A file rather than a run: block, so the promotion route can call it directly, and so a
# linter can read it as the script it is.

set -euo pipefail

# This used to be part of the implement prompt. It is deterministic work, and leaving it
# to the agent made every implement touch the same file: two runs whose branches were cut
# before the other merged conflicted here, produced correct code, and still failed to open
# a pull request. Doing it after the merge means exactly one writer, always against a
# current default branch.

# Which stages get an entry is the profile's answer, not this file's (FR-023). A release
# repository records one when a change reaches production and not on the way there; a
# repository that keeps no changelog lists nothing and every call here is a no-op.
#
# An empty list means no stage, which is also what an absent `changelogOn` projects to: the
# optional token takes its whole line with it and the input defaults to empty.
if [ -n "${STAGE:-}" ]; then
  listed=false
  while IFS= read -r candidate; do
    [ "$candidate" = "$STAGE" ] || continue
    listed=true
    break
  done < <(printf '%s\n' "${CHANGELOG_STAGES:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ "$listed" != true ]; then
    echo "::notice::${STAGE} is not one of the stages this repository records in its changelog (${CHANGELOG_STAGES:-none}); nothing to add."
    exit 0
  fi
fi

git config user.name "$GIT_IDENTITY"
git config user.email "${GIT_IDENTITY}@users.noreply.github.com"

# The caller is already on the branch this entry belongs to: the promotion route creates the
# head, cherry-picks onto it, and calls this before it pushes. Checking out a stage here and
# pushing it was rejected by protection on every stage a person gates, which is the ones
# that matter (FR-031).
#
# Naming a branch is the only thing here that reaches the network, so it is the only thing
# that sets up a remote and a credential. Doing that unconditionally rewrote `origin` in the
# middle of a promotion run that was about to push to it, and installed a token for a commit
# that is made locally and pushed by somebody else.
if [ -n "${HEAD_BRANCH:-}" ]; then
  host="${GITHUB_SERVER_URL#https://}"
  git remote set-url origin "https://${host}/${GITHUB_REPOSITORY}.git"

  # The token is carried per command, not embedded in the remote URL (FR-067). A URL
  # credential is written into .git/config, printed by anything that reports the remote, and
  # inherited by every later step in the job; this reaches git through its own environment
  # and no further.
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=http.extraheader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

  git fetch --quiet origin "$HEAD_BRANCH"
  git checkout --quiet -B "$HEAD_BRANCH" "origin/$HEAD_BRANCH"
fi

if [ -z "$CHANGELOG_PATH" ]; then
  echo "::notice::This repository keeps no changelog, so there is nothing to record."
  exit 0
fi

if [ ! -f "$CHANGELOG_PATH" ]; then
  echo "::notice::$CHANGELOG_PATH does not exist; nothing to update."
  exit 0
fi

# Idempotent: a re-run, a retry, or a second call for the same commit must not add a
# duplicate row.
short_sha="${COMMIT_SHA:0:7}"
if jq -e --arg c "$short_sha" '.changes[]? | select(.commit == $c)' "$CHANGELOG_PATH" >/dev/null 2>&1; then
  echo "::notice::$short_sha is already in the changelog."
  exit 0
fi

title=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title --jq '.title')

# The commit subject carries what actually changed. Strip the conventional-commit prefix
# and the trailing issue reference so the summary reads as prose rather than as a commit.
subject=$(git log -1 --format=%s "$COMMIT_SHA")
summary=$(printf '%s' "$subject" \
  | sed -E 's/^[a-z]+(\([^)]*\))?!?: *//' \
  | sed -E 's/ *\(#[0-9]+\) *$//')
[ -n "$summary" ] || summary="$title"
# Capitalise, because a commit subject conventionally starts lowercase and this is read
# by people rather than by tooling.
summary="$(printf '%s' "${summary:0:1}" | tr '[:lower:]' '[:upper:]')${summary:1}"

timestamp=$(git log -1 --format=%cI "$COMMIT_SHA")

tmp=$(mktemp)
jq --argjson n "$MAX_ENTRIES" \
   --arg ts "$timestamp" \
   --argjson issue "$ISSUE_NUMBER" \
   --arg title "$title" \
   --arg summary "$summary" \
   --arg commit "$short_sha" \
   '.changes = ([{timestamp: $ts, issue: $issue, title: $title, summary: $summary, commit: $commit}] + (.changes // []))[:$n]' \
   "$CHANGELOG_PATH" > "$tmp"
mv "$tmp" "$CHANGELOG_PATH"

if git diff --quiet -- "$CHANGELOG_PATH"; then
  echo "::notice::changelog unchanged."
  exit 0
fi

git add -- "$CHANGELOG_PATH"
git commit --quiet -m "docs(changelog): record #${ISSUE_NUMBER}"

# No push. The commit sits on the head the caller built, and the caller pushes it
# with the rest of the promotion -- one branch, one push, one pull request. An
# action that pushed on its own could leave a changelog entry on a branch whose
# promotion then failed to open.
echo "Recorded #${ISSUE_NUMBER} at ${short_sha} in the changelog, on $(git rev-parse --abbrev-ref HEAD)."
