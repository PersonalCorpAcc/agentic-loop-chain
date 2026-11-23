#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/confirm-review-subject/confirm-review-subject.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is this a pull request apply-review may work on, with feedback still to apply?
#
# Writes `found=false` when the pull request is not open, was authored by a person, or has
# nothing unresolved on its head. Otherwise writes `found=true`, `pr`, `issue` (possibly
# empty), `unresolved` (a count) and `threads` (the unresolved items as one line of JSON) to
# GITHUB_OUTPUT.
#
# Environment: GH_TOKEN, REPO, PR, LINKED_ISSUE (the router's, may be empty), RESOLVED_ISSUE
# (from the App's linkage, may be empty), GITHUB_OUTPUT.

set -euo pipefail

none() {
  echo "found=false" >> "$GITHUB_OUTPUT"
  echo "$1"
  exit 0
}

pr=$(gh pr view "$PR" --repo "$REPO" --json number,state,author,title,body)
[ "$(printf '%s' "$pr" | jq -r '.state')" = "OPEN" ] || none "PR #$PR is not open"

# Use GitHub's bot flag because App login formats differ across APIs.
author=$(printf '%s' "$pr" | jq -r '.author.login')
is_bot=$(printf '%s' "$pr" | jq -r '.author.is_bot')
[ "$is_bot" = "true" ] || \
  none "PR #$PR was authored by $author, a human. Never push to a human's branch."

# The issue this pull request belongs to: the router's, then the App's recorded linkage -- the
# body carries no closing keyword by design (FR-030) -- then a keyword a person wrote.
if [ -n "${LINKED_ISSUE:-}" ]; then
  issue="$LINKED_ISSUE"
elif [ -n "${RESOLVED_ISSUE:-}" ]; then
  issue="$RESOLVED_ISSUE"
else
  issue=$(printf '%s' "$pr" | jq -r '.body // ""' \
            | grep -oiE '(close[sd]?|fixe?[sd]?|resolve[sd]?) +#[0-9]+' \
            | grep -oE '[0-9]+' | head -n 1 || true)
fi

# Unresolved review threads, from the API rather than from the model's reading of it. The
# threads themselves are carried, not just how many: the agent's push outdates every thread it
# fixes, so this is the only moment the set can be read (T245).
#
# A change request written as a review body, with no inline comment, opens no thread, and was
# dropped as "no substantive unresolved feedback" (loopscope #319 and #329, 22/11/2026). So the
# latest one a person made on the current head joins the set as one item, keyed by the
# review's own ID; a push moves the head and retires it, as a push outdates a thread (FR-118).
# The dollar signs are GraphQL and jq variables, not the shell's.
# shellcheck disable=SC2016
threads=$(gh api graphql -f query='
  query($owner:String!, $name:String!, $number:Int!) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$number) {
        headRefOid
        reviewThreads(first:100) { nodes { id isResolved isOutdated } }
        reviews(last:30, states:CHANGES_REQUESTED) {
          nodes { id body author { __typename login } commit { oid } }
        }
      }
    }
  }' \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR" \
  --jq '.data.repository.pullRequest
          | .headRefOid as $head
          | [.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)]
            + ([.reviews.nodes[]
                | select(.author.__typename == "User" and .commit.oid == $head
                         and ((.body // "") | test("\\S")))]
               | if length > 0 then [last | {id, isResolved: false, isOutdated: false,
                   kind: "review", author: .author.login, body}] else [] end)' | jq -c .)
# gh's jq option takes an expression only: given the compact flag first, gh read the flag as
# the filter and the filter as a second endpoint, and failed "accepts 1 arg(s), received 2" on
# the first review anyone requested (loopscope PR #158, 20/11/2026).
unresolved=$(printf '%s' "$threads" | jq 'length')

# Measured and then acted on. Two events arrive for one review -- the submission and each of
# its comments -- and the `pr-feedback-<pr>` group serialises them, so the second starts after
# the first has pushed its fix and outdated the thread it fixed. Without this it ran a second
# agent over a pull request with nothing outstanding (T245).
[ "$unresolved" -gt 0 ] || \
  none "PR #$PR has no unresolved review threads or change request on its head; the feedback has already been applied."

{
  echo "found=true"
  echo "pr=$PR"
  echo "issue=${issue:-}"
  echo "unresolved=$unresolved"
  echo "threads=$threads"
} >> "$GITHUB_OUTPUT"
echo "PR #$PR has $unresolved unresolved thread(s)"
