#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/resolve-change-linkage/resolve-change-linkage.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Which pull request and branch belong to this change, read from the comment the App wrote
# (FR-064).
#
# Two sources, and they are not equal. A comment authored by the bot identity and recorded
# by the forge as performed through the App is a fact about what this loop did: a human can
# write the same words, but not with that record. A marker in the issue body is a hint,
# because anyone can type an HTML comment invisibly and because the next thing to edit the
# body replaces it. Both are reported, and `source` says which one answered, so a caller
# that must not act on an unverified linkage can tell the difference rather than guess.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "resolve-change-linkage: jq is not on PATH. Every comment would read as unparseable and the answer would be a silent 'no linkage'." >&2
  exit 1
fi

: "${REPO:?resolve-change-linkage: REPO is required}"
: "${ISSUE_NUMBER:?resolve-change-linkage: ISSUE_NUMBER is required}"

case "$ISSUE_NUMBER" in
  '' | *[!0-9]*)
    echo "resolve-change-linkage: '${ISSUE_NUMBER}' is not an issue number." >&2
    exit 1
    ;;
esac

pr=""
branch=""
source="none"

marker_value() {
  # The last marker wins: a comment is rewritten in place, so the newest text is the
  # authority within it.
  grep -oE "<!-- ${1}: [^ ]+ -->" | sed -E "s/<!-- ${1}: (.*) -->/\\1/" | tail -n1 || true
}

# The newest App comment first: a re-implement updates the comment in place, but a
# consumer that deleted one and let the loop write another has two.
authored="$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate \
  --jq "[.[]
    | select(.performed_via_github_app != null)
    | select((.user.login // \"\") | ascii_downcase == (\"${BOT_LOGIN:-}\" | ascii_downcase))
    | select(.body | contains(\"<!-- implement-pr:\"))
    | .body] | last // empty" 2>/dev/null || true)"

if [ -n "$authored" ]; then
  pr="$(printf '%s' "$authored" | marker_value "implement-pr")"
  branch="$(printf '%s' "$authored" | marker_value "implement-branch")"
  source="comment"
  echo "Issue #${ISSUE_NUMBER}: linkage from the App's own comment (pull request ${pr:-<none>}, branch ${branch:-<none>})."
else
  body="$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body // ""' 2>/dev/null || true)"
  pr="$(printf '%s' "$body" | marker_value "implement-pr")"
  branch="$(printf '%s' "$body" | marker_value "implement-branch")"
  if [ -n "$pr" ] || [ -n "$branch" ]; then
    source="body"
    echo "::warning::Issue #${ISSUE_NUMBER}: no App-authored linkage comment; falling back to the body markers, which anyone can write and anything can overwrite (pull request ${pr:-<none>}, branch ${branch:-<none>})."
  else
    echo "Issue #${ISSUE_NUMBER}: nothing has recorded a pull request or branch for this change."
  fi
fi

case "$pr" in
  *[!0-9]*) pr="" ;;
esac

{
  echo "pr=${pr}"
  echo "branch=${branch}"
  echo "source=${source}"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
