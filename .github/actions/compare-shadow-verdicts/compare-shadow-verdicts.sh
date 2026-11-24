#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/compare-shadow-verdicts/compare-shadow-verdicts.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# How often the merge gate, run in shadow on people's pull requests, agreed with the people
# (feature 007 X11, FR-027). For every pull request a person opened that closed in the last
# DAYS days and carries the gate's advisory marker, the gate's verdict is set beside what the
# people did:
#
#   merged, with no change request standing        approve
#   merged over a standing change request          review
#   closed without merging                         review
#
# and the two are counted. The disagreements are listed, the dangerous kind first: the gate
# approved what the people held back. Deterministic and read-only, so it can run anywhere a
# token can read the repository; the canary cycle runs it after each cycle, and by hand it is
#
#   GH_TOKEN=<token> REPO=owner/name bash .github/actions/compare-shadow-verdicts/compare-shadow-verdicts.sh
#
# The advisory comment counts only when the workflow token wrote it, so a marker anybody else
# types is not a verdict, and the newest one wins. A pull request the canary's monthly red team
# opened is left out: its verdict is that run's assertion, not a human decision to compare with.
#
# Inputs: REPO, GH_TOKEN; DAYS (30); SINCE (YYYY-MM-DD, overrides DAYS); LIMIT (200).
# Outputs: compared, agreed, disagreed, looser (the gate approved, the people held), stricter.

set -euo pipefail

: "${REPO:?compare-shadow-verdicts: REPO is required}"

DAYS="${DAYS:-30}"
LIMIT="${LIMIT:-200}"
SINCE="${SINCE:-$(date -u -d "-${DAYS} days" +%Y-%m-%d)}"
out="${GITHUB_OUTPUT:-/dev/null}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# One line per comparable pull request: number, advisory verdict, the people's decision, title.
# jq variables, not shell ones.
# shellcheck disable=SC2016
rows="$(gh pr list --repo "$REPO" --state closed --search "closed:>=${SINCE}" --limit "$LIMIT" \
  --json number,title,author,mergedAt,reviewDecision,comments \
  --jq '.[]
    | select(.author.is_bot != true)
    | select([.comments[]? | (.body // "") | contains("<!-- canary-red-team")] | any | not)
    | . as $pr
    | ([.comments[]?
        | select((.author.login // "") | test("^github-actions(\\[bot\\])?$"))
        | (.body // "") | capture("<!-- agent-merge-gate-advisory: (?<v>[a-z]+) -->")?
        | .v] | last) as $advice
    | select($advice != null)
    | (if $pr.mergedAt != null and ($pr.reviewDecision // "") != "CHANGES_REQUESTED" then "approve" else "review" end) as $people
    | [($pr.number | tostring), $advice, $people, ($pr.title | gsub("[\t\n\r]"; " "))] | @tsv')"

compared=0
agreed=0
looser=()
stricter=()
while IFS=$'\t' read -r number advice people title; do
  [ -n "${number:-}" ] || continue
  compared=$((compared + 1))
  if [ "$advice" = "$people" ]; then
    agreed=$((agreed + 1))
  elif [ "$advice" = approve ]; then
    looser+=("#${number} ${title}")
  else
    stricter+=("#${number} ${title}")
  fi
done <<<"$rows"
disagreed=$((compared - agreed))

{
  echo "compared=${compared}"
  echo "agreed=${agreed}"
  echo "disagreed=${disagreed}"
  echo "looser=${#looser[@]}"
  echo "stricter=${#stricter[@]}"
} >>"$out"

{
  echo "### The merge gate in shadow, since ${SINCE}"
  echo
  if [ "$compared" -eq 0 ]; then
    echo "No pull request a person opened has closed with the gate's advice on it since ${SINCE}."
  else
    echo "${compared} pull request(s) people opened closed with the gate's advice on them: the gate agreed with the people on ${agreed} ($(( agreed * 100 / compared ))%) and disagreed on ${disagreed}."
    if [ "${#looser[@]}" -gt 0 ]; then
      echo
      echo "The gate would have approved what the people held back:"
      printf -- '- %s\n' "${looser[@]}"
    fi
    if [ "${#stricter[@]}" -gt 0 ]; then
      echo
      echo "The gate would have held back what the people merged:"
      printf -- '- %s\n' "${stricter[@]}"
    fi
  fi
} >>"$summary"
