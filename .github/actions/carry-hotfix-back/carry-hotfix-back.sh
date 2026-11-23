#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/carry-hotfix-back/carry-hotfix-back.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Cherry-pick a hotfix that merged into a release branch onto the trunk and open the
# carry-back pull request (FR-055). Run from a full-history checkout whose `origin` the App
# token can push to, after decide-hotfix-back.sh said `carry=true`.
#
# Writes `carried=true` to GITHUB_OUTPUT when a pull request was opened. A hotfix the trunk
# already has, or one that does not apply cleanly, pushes nothing and exits 0; the second is
# reported as needing a person.
#
# Environment: GH_TOKEN, REPO, PR, BASE_REF, ISSUE, TRUNK, GIT_IDENTITY, TITLE_PREFIX,
# GITHUB_RUN_ID, GITHUB_OUTPUT.

set -euo pipefail

git config user.name "$GIT_IDENTITY"
git config user.email "${GIT_IDENTITY}@users.noreply.github.com"

merged="$(gh api "repos/$REPO/pulls/$PR" --jq '.merge_commit_sha // empty')"
[ -n "$merged" ] || { echo "::warning::PR #${PR} reports no merge commit; nothing to carry back."; exit 0; }
# Fetched before it is named: a checkout brings down what the run needs and nothing else, and
# handing an unfetched sha to git exits 128.
git fetch --no-tags --quiet origin "$merged" "$TRUNK" || true

if git merge-base --is-ancestor "$merged" "origin/${TRUNK}" 2>/dev/null; then
  echo "${TRUNK} already has ${merged:0:8}; nothing to carry back."
  exit 0
fi

branch="hotfix-back/${ISSUE}-${GITHUB_RUN_ID}"
git switch --quiet --detach "origin/${TRUNK}"
git switch --quiet -c "$branch"
if ! git cherry-pick -m 1 "$merged" >/dev/null 2>&1 && ! git cherry-pick "$merged" >/dev/null 2>&1; then
  files="$(git diff --name-only --diff-filter=U 2>/dev/null | head -n 20 | tr '\n' ' ')"
  git cherry-pick --abort >/dev/null 2>&1 || true
  echo "::warning::The hotfix on ${BASE_REF} does not apply cleanly onto ${TRUNK} (${files:-files not recorded}); nothing was pushed and it needs a person."
  exit 0
fi

git push --quiet origin "HEAD:refs/heads/${branch}"
# The same issue marker the original carried, so every reader that asks which issue a pull
# request belongs to gets the same answer for both halves of the hotfix.
body="$(printf '%s\n\n%s\n' \
  "Carries the hotfix that landed on \`${BASE_REF}\` in #${PR} back to \`${TRUNK}\`, so the next release branch is cut with it." \
  "<!-- implement-issue: ${ISSUE} -->")"
gh pr create --repo "$REPO" --base "$TRUNK" --head "$branch" \
  --title "${TITLE_PREFIX}carry hotfix #${ISSUE} back to ${TRUNK}" \
  --body "$body"
echo "carried=true" >> "$GITHUB_OUTPUT"
