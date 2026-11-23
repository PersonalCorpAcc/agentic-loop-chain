#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/phrase-assessment.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The sentences the prompt is given about this run: what the pull request is, what context
# to read, what has already been checked, and the notes for a promotion, advice and review
# mode (FR-024, FR-027, FR-056).
#
# Environment: PROMOTION, ADVISE, PR, ISSUE, ISSUE_CONTEXT_PATH, VERIFY_COMMAND,
# IMPLEMENT_LABEL, GATE_MODE, BASE, VERDICT_WORD.
# Outputs: mode_note, subject_clause, context_instruction, promotion_note, checked_note,
# advise_note.

set -euo pipefail
# Review mode (feature 007 X08, FR-024): the agent reviews and never pushes. Advice
# (below) already changes nothing and says so itself.
if [ "${GATE_MODE:-fix}" = review ] && [ "${ADVISE:-false}" != true ]; then
  {
    echo "mode_note<<EOF_MODE"
    echo "**Review mode: you never push.** This repository's merge gate reviews and does not fix. Steps 4b and 6 do not apply: do not merge the base in, resolve a conflict, fix CI, commit, or call \`push_to_pull_request_branch\`. Instead:"
    echo ""
    echo "- Verify every finding before you list it: read the lines it is about, and for a CI failure the log lines that show it. Cite the file and line. Do not list anything you have not checked."
    echo "- List the findings in a \`### Findings\` section, worst first, one per line: \`- [blocker] <file>:<line> -- <what is wrong> -- <what to change>\`, and the same with \`[major]\` and \`[minor]\`. A blocker is a failed CI job, a conflict with the base (say: merge \`origin/${BASE}\` into the branch, never rebase, and resolve it), an acceptance criterion the change does not meet, or a defect it introduces. A major is a gap it should not ship with: new behaviour with no test, or a case the acceptance criteria name that the code misses. A minor is anything else worth saying; minors never hold a change."
    echo "- The verdict is \`${VERDICT_WORD}\` when there is no blocker and no major; \`changes\` when there are, and an agent could make them from your findings; \`review\` when a person must judge: checks 2, 3, 5, 6 or 8 flagged, low confidence, or a failure you cannot explain. \`remediated\` is not available. The workflow requests the changes as a pull-request review, apply-review makes them, and you review again when CI has run."
    echo "EOF_MODE"
  } >> "$GITHUB_OUTPUT"
else
  echo "mode_note=" >> "$GITHUB_OUTPUT"
fi
if [ "${ADVISE:-false}" = true ]; then
  # Advise only (feature 007 X11, FR-027). The rest of the prompt is written for a
  # pull request this loop opened and may push to; this note comes first and says
  # which parts of it do not apply.
  if [ -n "${ISSUE:-}" ]; then
    echo "subject_clause=was opened by a person, not by this loop, and refers to issue **#${ISSUE}**" >> "$GITHUB_OUTPUT"
    echo "context_instruction=Read \`${ISSUE_CONTEXT_PATH}\`. It contains the issue this pull request refers to and its discussion; its acceptance criteria are what the change should satisfy." >> "$GITHUB_OUTPUT"
  else
    echo "subject_clause=was opened by a person, not by this loop, and names no issue" >> "$GITHUB_OUTPUT"
    echo "context_instruction=There is no issue context: this pull request names no issue. Assess it on its diff, its title and body in \`/tmp/gh-aw/agent/pr.json\`, and the CI conclusion; for check 7, compare the diff with what the title and body say it does." >> "$GITHUB_OUTPUT"
  fi
  {
    echo "promotion_note="
    echo "checked_note=It has already been confirmed that this is an open pull request from this repository. Do not re-check that, and do not poll for checks: the conclusion above is the answer."
    echo "advise_note<<EOF_ADVISE"
    echo "**Advise only: change nothing.** A person opened this pull request. This repository runs the gate in shadow on such pull requests so that your judgement can be compared with the decisions of the people who review them. Your whole job is the assessment and a verdict:"
    echo ""
    echo "- Do not commit, push, merge the base in, resolve a conflict, fix CI or remediate anything, and never call \`push_to_pull_request_branch\`. Steps 4b and 6 do not apply: where they would have you act, select \`review\` and say in your findings what you would have fixed."
    echo "- Do not add or remove labels, approve, merge or close anything, and write nothing but the one comment below."
    echo "- The only verdicts are \`approve\`, when every check passes, and \`review\` for anything else, a failed or missing CI result included. \`remediated\` is not available."
    echo "- Emit exactly one \`add_comment\` targeting pull request #${PR}, in the format step 8 describes. The workflow posts it as advice, and nothing else happens."
    echo "EOF_ADVISE"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "advise_note=" >> "$GITHUB_OUTPUT"
echo "checked_note=It has already been confirmed that this is an open pull request we authored, that it closes an issue, and that the issue carries \`${IMPLEMENT_LABEL}\`. Do not re-check any of that, and do not poll for checks: the conclusion above is the answer." >> "$GITHUB_OUTPUT"
if [ "${PROMOTION:-false}" = true ]; then
  {
    echo "subject_clause=promotes a set of changes, one of which is issue **#${ISSUE}**"
    echo "promotion_note<<EOF_NOTE"
    echo "This is a **promotion**. Its head is a snapshot of the stage below, so it carries several changes, each of which already passed this gate on its way to that stage; its body names every issue it carries. You are not re-assessing them one by one. What you are assessing is the promotion itself: that CI is green on the combination, that nothing in the diff is a file this repository protects, and that the set is what the body says it is. Post your assessment on this pull request, and do not touch any issue."
    echo "EOF_NOTE"
    echo "context_instruction=There is no issue context on a promotion: it carries several issues, and any one of their acceptance criteria would be the wrong measure for the rest. The diff and the CI conclusion are what you have, and they are what a promotion is assessed on."
  } >> "$GITHUB_OUTPUT"
else
  {
    echo "subject_clause=closes issue **#${ISSUE}**"
    echo "promotion_note="
    echo "context_instruction=Read \`${ISSUE_CONTEXT_PATH}\`. It contains the issue body and its discussion. When running \`/${VERIFY_COMMAND}\`, the acceptance criteria there define what the implementation must satisfy."
  } >> "$GITHUB_OUTPUT"
fi
