#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/retry-pending/release-stale-pending.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Hand to a person an issue that still says its pull request is pending when that pull request
# closed long ago (FR-141). The reconcile belt runs this on every pass.
#
# The pending-pull-request label has one exit: the stage-merge route, on the pull request's `closed` event. If that
# event is lost, or a step before the label clear fails (a 5xx, a missing `merged-<stage>`
# label), the issue says "in flight" for ever, and every other sweep, the orphan restart
# included, leaves it alone because of exactly that label. This reads state: the issue's linked
# pull request, through the same script the router's other sweeps use, and its closing time.
# Rebuilding what stage-merge would have done is stage-merge's job and needs its event, so this
# does the one safe thing: says what it found and hands the issue to a person, once.
#
# Reads: REPO, GH_TOKEN, PR_PENDING_LABEL, REVIEW_LABEL, BOT_LOGIN, STALE_MINUTES (default 30);
#        NOW for tests.
set -euo pipefail

now="${NOW:-$(date -u +%s)}"
stale="${STALE_MINUTES:-30}"
marker="<!-- agent-stale-pending-pr -->"
linkage="$(dirname "${BASH_SOURCE[0]}")/../resolve-change-linkage/resolve-change-linkage.sh"

issues="$(gh issue list --repo "$REPO" --label "$PR_PENDING_LABEL" --state open --limit 100 \
  --json number,labels --jq ".[] | select([.labels[].name] | index(\"${REVIEW_LABEL}\") | not) | .number")"

while IFS= read -r issue; do
  case "$issue" in '' | *[!0-9]*) continue ;; esac

  # A failed lookup leaves the label: it is only released on an answer.
  if ! pr="$(GITHUB_OUTPUT=/dev/stdout GH_TOKEN="${GH_TOKEN:-}" REPO="$REPO" ISSUE_NUMBER="$issue" BOT_LOGIN="${BOT_LOGIN:-}" \
    bash "$linkage" 2>/dev/null | sed -n 's/^pr=//p' | head -1)"; then
    echo "::warning::Could not read #$issue's linkage; leaving ${PR_PENDING_LABEL} until the next sweep."
    continue
  fi
  [ -n "$pr" ] || continue

  info="$(gh pr view "$pr" --repo "$REPO" --json state,closedAt --jq '[.state, (.closedAt // "")] | @tsv' 2>/dev/null || true)"
  IFS=$'\t' read -r state closed <<<"$info"
  case "$state" in MERGED | CLOSED) ;; *) continue ;; esac
  [ -n "${closed:-}" ] || continue
  age=$(( (now - $(date -u -d "$closed" +%s)) / 60 ))
  if [ "$age" -lt "$stale" ]; then
    echo "#$issue: its pull request #$pr is ${state,,}, ${age}m ago; stage-merge may still be on its way."
    continue
  fi

  echo "#$issue: still ${PR_PENDING_LABEL} although pull request #$pr was ${state,,} ${age}m ago; handing it to a person."
  gh issue edit "$issue" --repo "$REPO" --remove-label "$PR_PENDING_LABEL" --add-label "$REVIEW_LABEL" >/dev/null 2>&1 ||
    { echo "::warning::Could not relabel #$issue; the next sweep will try again."; continue; }
  already="$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --paginate \
    --jq ".[] | select(.body | contains(\"$marker\")) | .id" 2>/dev/null | grep -c . || true)"
  if [ "${already:-0}" -eq 0 ]; then
    gh issue comment "$issue" --repo "$REPO" --body "${marker}
Pull request #${pr} was ${state,,} ${age} minutes ago, but this issue still said \`${PR_PENDING_LABEL}\`: the loop's follow-up for a closed pull request never ran, so its stage labels may be out of date. It now carries \`${REVIEW_LABEL}\` for a person to check." >/dev/null 2>&1 || true
  fi
done <<<"$issues"
