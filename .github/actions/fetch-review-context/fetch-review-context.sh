#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/fetch-review-context/fetch-review-context.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Everything apply-review's agent reads about a pull request's review, written to disk before it
# starts. A reviewer often makes one point across several comments, so the agent needs the whole
# conversation, not just the comment that triggered it.
#
# Environment: GH_TOKEN, REPO, PR, THREADS (the subject job's unresolved items as JSON, may be
# empty), AGENT_DIR (default /tmp/gh-aw/agent).
# Writes: change-requests.json, diff.patch, review-comments.json, conversation.json,
# review-threads.json.

set -euo pipefail
dir="${AGENT_DIR:-/tmp/gh-aw/agent}"
mkdir -p "$dir"
# The change request made as a review body, as the subject job selected it (FR-118).
printf '%s' "${THREADS:-[]}" | jq '[.[] | select(.kind == "review")]' > "$dir/change-requests.json"
# gh 2.97 refuses to print a diff holding a terminal escape sequence, so a pull request that adds
# one (a test stripping colour codes, loopscope #348) crashed this step. The file is read as
# text, not shown on a terminal: pass the flag wherever this gh offers it (FR-119).
diff_flags=()
if gh pr diff --help 2>&1 | grep -q -- '--allow-escape-sequences'; then diff_flags=(--allow-escape-sequences); fi
gh pr diff "$PR" --repo "$REPO" "${diff_flags[@]}" > "$dir/diff.patch"
gh api "repos/$REPO/pulls/$PR/comments" --paginate \
  --jq '[.[] | {id, path, line, author: .user.login, body, in_reply_to_id}]' \
  > "$dir/review-comments.json"
gh api "repos/$REPO/issues/$PR/comments" --paginate \
  --jq '[.[] | {author: .user.login, body}]' \
  > "$dir/conversation.json"
# shellcheck disable=SC2016 # $owner, $name and $number are GraphQL's, not the shell's
gh api graphql -f query='
  query($owner:String!, $name:String!, $number:Int!) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$number) {
        reviewThreads(first:100) {
          nodes { id
            isResolved isOutdated path
            comments(first:50) { nodes { author { login } body } }
          }
        }
      }
    }
  }' \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes' \
  > "$dir/review-threads.json"
