#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/gate-review/decide-review-outcome.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The merge gate's verdict under `gate.mode: review` (feature 007 X08, FR-024), from what the
# agent wrote and the rules the workflow owns.
#
# In review mode the agent never pushes. It ranks each finding `blocker`, `major` or `minor`, one
# per line as `- [blocker] ...`, and says `approve` (or `merge`), `changes` or `review`. Then:
#
#   - Only blockers and majors request changes; minors are listed and do not hold anything. An
#     approval that lists a blocker or a major is a request for changes: the rule may make the
#     verdict stricter than the agent's, never looser (Principle III).
#   - A request for changes that lists no blocker or major is not an answer, and is invalid.
#   - A promotion is not changed by apply-review: it carries changes that each passed the gate,
#     and a request for changes on it goes to a person instead.
#   - The rounds are capped. Each change request the gate has already made on this pull request
#     is one round; at the cap the request goes to a person rather than round again.
#
# Inputs: OUTCOME (the validator's), VALID, OUTPUT_FILE, COMMENT_TARGET, PR, PROMOTION,
# MAX_ROUNDS, GATE_REVIEW_MARKER, REPO, GH_TOKEN.
# Outputs: outcome, valid, blockers, majors, minors, round (the one a change request would be),
# why (a sentence when the rule changed the agent's verdict).

set -euo pipefail

: "${REPO:?decide-review-outcome: REPO is required}"
: "${PR:?decide-review-outcome: PR is required}"
marker="${GATE_REVIEW_MARKER:-<!-- agent-merge-gate-review -->}"
max_rounds="${MAX_ROUNDS:-5}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
outcome="${OUTCOME:-invalid}"
why=""

body=""
if [ -n "${OUTPUT_FILE:-}" ] && [ -f "$OUTPUT_FILE" ]; then
  body="$(jq -r --arg target "${COMMENT_TARGET:-$PR}" --arg pr "$PR" '
    [.items[]? | select(.type == "add_comment" and (.body | type == "string"))
      | select((.item_number | tostring) as $n | $n == $target or $n == $pr)] | .[0].body // ""' "$OUTPUT_FILE" | tr -d '\r')"
fi
count() { printf '%s\n' "$body" | grep -ciE "^[[:space:]]*[-*][[:space:]]+\[$1\]" || true; }
blockers="$(count blocker)"
majors="$(count major)"
minors="$(count minor)"
serious=$((blockers + majors))

case "$outcome" in
  merge | approve)
    if [ "$serious" -gt 0 ]; then
      why="The agent said ${outcome} and listed ${blockers} blocker(s) and ${majors} major finding(s); those request changes."
      outcome=changes
    fi
    ;;
  changes)
    if [ "$serious" -eq 0 ]; then
      why="The agent asked for changes and listed no blocker or major finding, so there is nothing to ask for."
      outcome=invalid
    fi
    ;;
esac

round=0
if [ "$outcome" = changes ]; then
  if [ "${PROMOTION:-false}" = true ]; then
    why="${why:+$why }A promotion is not changed by apply-review: it carries changes that each passed the gate, so it goes to a person."
    outcome=review
  else
    made="$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews?per_page=100" |
      MARKER="$marker" jq -s 'add // [] | [.[] | select(.state == "CHANGES_REQUESTED" and .user.type == "Bot" and ((.body // "") | contains(env.MARKER)))] | length')"
    round=$((made + 1))
    if [ "$round" -gt "$max_rounds" ]; then
      why="${why:+$why }The gate has already asked for changes ${made} time(s) on this pull request, the most this repository allows, so it goes to a person."
      outcome=review
    fi
  fi
fi

{
  echo "outcome=${outcome}"
  echo "valid=$([ "$outcome" != invalid ] && echo true || echo false)"
  echo "blockers=${blockers}"
  echo "majors=${majors}"
  echo "minors=${minors}"
  echo "round=${round}"
  echo "why=${why}"
} >>"$out"
echo "Review mode: ${outcome} (${blockers} blocker, ${majors} major, ${minors} minor)${why:+. $why}"
