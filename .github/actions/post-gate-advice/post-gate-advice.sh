#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/post-gate-advice/post-gate-advice.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The merge gate's one write in shadow mode (feature 007 X11, FR-027). On a pull request a person
# opened, the gate assesses and advises: one comment on the pull request carrying the verdict in
# a marker the comparison reads, `<!-- agent-merge-gate-advisory: <verdict> -->`, and the
# findings. Nothing else is written: no label, push, merge, approval or issue comment.
#
# The verdict is `approve` or `review`. Where a rule would have handed the pull request to a
# person without starting the agent -- a protected file or a weakened test on green CI, a
# standing change request, a conflict this repository does not let the agent resolve -- the
# rule's answer is the advice, and says so. Otherwise it is the agent's verdict as the
# validator read it, with its assessment as the findings. An agent that pushed, or gave no
# usable verdict, has no advice to give, and nothing is posted.
#
# Inputs, from the environment:
#   REPO, PR, GH_TOKEN      where to post, with a token whose comment raises no event
#   CONCLUSION              the CI conclusion the gate assessed
#   OUTPUT_FILE             the agent's agent_output.json, when the agent ran
#   AGENT_RESULT            the agent job's result
#   VALID, OUTCOME          what validate-merge-gate-output made of it
#   REQUIRES_REVIEW         protected_changes: a protected file or a weakened test
#   PROTECTED_LIST          the files it named, one per line
#   REVIEW_BLOCKED          a reviewer's change request stands
#   CONFLICT_BLOCKED        a conflict this repository hands to a person
#   RUN_URL                 this run
# Outputs: verdict (empty when there is none), source (rule or agent), why (when empty).

set -euo pipefail

: "${REPO:?post-gate-advice: REPO is required}"
: "${PR:?post-gate-advice: PR is required}"

out="${GITHUB_OUTPUT:-/dev/stdout}"
marker_prefix="<!-- agent-merge-gate-advisory"
verdict=""
source=""
findings=""

if [ "${REQUIRES_REVIEW:-false}" = true ] && [ "${CONCLUSION:-}" != failure ]; then
  verdict=review
  source=rule
  # The backticks are Markdown, not a command substitution.
  # shellcheck disable=SC2016
  findings="It changes a file this repository protects, or deletes, renames or skips a test, so the gate hands it to a person without an assessment:

$(printf '%s\n' "${PROTECTED_LIST:-}" | sed '/^[[:space:]]*$/d; s/^/- `/; s/$/`/')"
elif [ "${REVIEW_BLOCKED:-false}" = true ]; then
  verdict=review
  source=rule
  findings="A reviewer has requested changes, and the gate leaves a pull request alone until they are answered."
elif [ "${CONFLICT_BLOCKED:-false}" = true ]; then
  verdict=review
  source=rule
  findings="It conflicts with its base, and this repository hands a conflict to a person rather than to the agent."
elif [ "${VALID:-false}" = true ]; then
  case "${OUTCOME:-}" in
    merge | approve) verdict=approve ;;
    review) verdict=review ;;
  esac
  if [ -n "$verdict" ]; then
    source=agent
    body=""
    if [ -n "${OUTPUT_FILE:-}" ] && [ -f "$OUTPUT_FILE" ]; then
      body="$(jq -r --arg pr "$PR" '
        [.items[]? | select(.type == "add_comment" and (.body | type == "string"))] as $comments
        | ([$comments[] | select((.item_number | tostring) == $pr)] + $comments)
        | .[0].body // ""' "$OUTPUT_FILE" | tr -d '\r')"
    fi
    # The agent's words are findings, not markers. A marker line it wrote -- the gate's own, or
    # an advisory one -- would be read by the belt or the comparison as a verdict this workflow
    # did not give, and its Verdict line is renamed for the same reason.
    findings="$(printf '%s\n' "$body" | { grep -v -e '<!-- agent-merge-gate' || true; } | sed 's/\*\*Verdict:\*\*/**Agent verdict:**/g')"
  fi
fi

if [ -z "$verdict" ]; then
  if [ "${AGENT_RESULT:-}" != success ]; then
    why="the agent did not finish (${AGENT_RESULT:-not run})."
  elif [ "${VALID:-false}" = true ]; then
    why="the agent answered '${OUTCOME:-}', which advice cannot give: it was told to change nothing."
  else
    why="the agent gave no usable verdict."
  fi
  {
    echo "verdict="
    echo "source="
    echo "why=${why}"
  } >>"$out"
  echo "No advice on PR #${PR}: ${why}"
  exit 0
fi

case "$source" in
  rule) decided="decided by the gate's own rules, without the agent" ;;
  *) decided="the agent's assessment" ;;
esac

file="$(mktemp)"
{
  echo "${marker_prefix}: ${verdict} -->"
  echo "**Merge gate, advice only.** This repository runs the merge gate in shadow on pull requests people open, to compare its judgement with theirs. Nothing was changed: no label, push, merge or approval. A person decides this pull request as usual."
  echo
  echo "**Advisory verdict:** ${verdict} (${decided}; CI concluded ${CONCLUSION:-unknown})"
  echo
  printf '%s\n' "$findings"
  echo
  echo "[View this workflow run](${RUN_URL:-})"
} >"$file"

gh pr comment "$PR" --repo "$REPO" --body-file "$file" >/dev/null
rm -f "$file"

{
  echo "verdict=${verdict}"
  echo "source=${source}"
  echo "why="
} >>"$out"
echo "Advised ${verdict} on PR #${PR} (${source})."
