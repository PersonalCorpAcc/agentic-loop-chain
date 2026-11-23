#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/ask-for-re-review/ask-for-re-review.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# After apply-review pushes a fix, ask the people whose change request still stands to look
# again (feature 007 FR-121).
#
# A change request stays in force until the person who made it approves, re-reviews or
# dismisses it, and the merge gate holds the pull request for a person while one stands. So
# after a correct fix nothing moved and nobody was told: loopscope #329 (22/11/2026) waited from
# 14:44 to 16:36 with the gate declining every run. The gate does not treat an old change
# request as answered -- that decision is the reviewer's -- so the loop asks for it instead: it
# re-requests each such person's review, which notifies them, and says so on the pull request.
#
# Reads REPO, PR and GH_TOKEN (the App's, so the comment is the bot's and the router ignores it).
set -euo pipefail

reviews="$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews?per_page=100" | jq -s 'add // []')"
# Each person's latest decisive review, in the order GitHub returns them (oldest first). A
# comment-only review neither makes nor clears a change request, so it is not decisive.
mapfile -t reviewers < <(jq -r '
  [.[] | select(.user.type == "User")
       | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
  | group_by(.user.login) | map(last) | map(select(.state == "CHANGES_REQUESTED")) | .[].user.login
' <<<"$reviews" | tr -d '\r')

if [ "${#reviewers[@]}" -eq 0 ]; then
  echo "No change request stands on PR #${PR}; nobody to ask."
  exit 0
fi

# Best effort: a reviewer who has since lost access cannot be re-requested, and the comment
# still says what is needed.
jq -n '{reviewers: $ARGS.positional}' --args "${reviewers[@]}" |
  gh api -X POST "repos/${REPO}/pulls/${PR}/requested_reviewers" --input - >/dev/null ||
  echo "::warning::Could not re-request review on PR #${PR} from ${reviewers[*]}."

head="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid[0:7]')"
mentions="$(printf '@%s ' "${reviewers[@]}")"
body="$(printf '%s\n\n%s' \
  "<!-- agent-apply-review-re-review -->" \
  "${mentions% }: the changes you requested are applied in \`${head}\`. Please re-review, or approve, so the merge gate can run: it holds a pull request while a change request stands.")"
gh api -X POST "repos/${REPO}/issues/${PR}/comments" -f body="$body" >/dev/null
echo "Asked ${reviewers[*]} to re-review PR #${PR}."
