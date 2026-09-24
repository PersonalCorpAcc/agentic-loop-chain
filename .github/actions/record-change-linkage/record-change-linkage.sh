#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/record-change-linkage/record-change-linkage.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The authoritative link between an issue and its change is a comment this App wrote
# (FR-064). A marker in a body is not: any human can type one invisibly, and a body is
# rewritten wholesale by anything that edits the issue, so the link disappears with no
# trace. A comment survives a body rewrite, and the forge records that it was performed
# through the App, which is what makes it checkable rather than merely present.
#
# One comment per marker key per issue: an existing App comment carrying the key is
# updated, so a re-implement replaces the link rather than leaving two.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "record-change-linkage: jq is not on PATH, so the existing comment cannot be found and a duplicate would be posted instead." >&2
  exit 1
fi

: "${REPO:?record-change-linkage: REPO is required}"
: "${ISSUE_NUMBER:?record-change-linkage: ISSUE_NUMBER is required}"
: "${MARKER_KEY:?record-change-linkage: MARKER_KEY is required}"
: "${COMMENT_BODY:?record-change-linkage: COMMENT_BODY is required}"

case "$ISSUE_NUMBER" in
  '' | *[!0-9]*)
    echo "record-change-linkage: '${ISSUE_NUMBER}' is not an issue number." >&2
    exit 1
    ;;
esac

printf '%s' "$COMMENT_BODY" >/tmp/change-linkage-body.md

# Only comments the forge recorded as performed through an App are candidates to update.
# A human's comment carrying the same marker is left exactly where it is: it is not this
# App's to edit, and overwriting it would hide what somebody said.
existing="$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate \
  --jq "[.[] | select(.performed_via_github_app != null) | select(.body | contains(\"<!-- ${MARKER_KEY}:\")) | .id] | last // empty")"

if [ -n "$existing" ]; then
  gh api --method PATCH "repos/${REPO}/issues/comments/${existing}" \
    --field body=@/tmp/change-linkage-body.md >/dev/null
  echo "Updated the App-authored ${MARKER_KEY} comment on #${ISSUE_NUMBER} (comment ${existing})."
else
  gh api --method POST "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    --field body=@/tmp/change-linkage-body.md >/dev/null
  echo "Posted the App-authored ${MARKER_KEY} comment on #${ISSUE_NUMBER}."
fi
