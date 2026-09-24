#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/verify-route-matrix/verify-route-matrix.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
# Exercise the router's real classifier. This sources classify-route.sh rather than
# restating it, so a change to the route table cannot pass here by being copied twice.
#
# This file greps workflow sources for literal `${{ ... }}` expressions on purpose.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_YML="${HERE}/../../workflows/work-router.yml"
IMPLEMENT_WORKER_MD="${HERE}/../../workflows/agent-implement.md"
MERGE_GATE_WORKER_MD="${HERE}/../../workflows/agent-merge-gate.md"

# The classifier refuses to load without jq, but say it in the matrix's own
# words too: eight red rows about routing is the wrong report for a missing tool.
if ! command -v jq >/dev/null 2>&1; then
  echo "verify-route-matrix: jq is not on PATH, so no route can be classified. Install jq and re-run; the matrix has not been evaluated." >&2
  exit 1
fi

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../classify-route/classify-route.sh
source "${HERE}/../classify-route/classify-route.sh"

PASS=0
FAIL=0

# Classify one event and read a single field out of the result.
route_field() {
  local field="$1"
  shift

  local key value
  local -a assignments=("$@")

  (
    unset EVENT ACTION LABEL ISSUE_LABELS EVENT_ISSUE_NUMBER EVENT_PR_NUMBER \
      COMMENT_ON_PR COMMENT_SENDER_TYPE RUN_PR_NUMBER RUN_CONCLUSION RUN_ID \
      SCHEDULE OPERATION INPUT_ISSUE_NUMBER INPUT_PR_NUMBER INPUT_MODE \
      INPUT_CI_CONCLUSION INPUT_CI_RUN_ID INPUT_TRIGGER_KIND \
      PR_MERGED PR_BASE_REF

    for assignment in "${assignments[@]}"; do
      key="${assignment%%=*}"
      value="${assignment#*=}"
      export "${key}=${value}"
    done

    classify_route | sed -n "s/^${field}=//p"
  )
}

assert() {
  local label="$1" expected="$2" actual="$3"

  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual" >&2
  fi
}

assert_route() {
  local label="$1" expected="$2"
  shift 2
  assert "$label" "$expected" "$(route_field route "$@")"
}

echo "── Label events ──────────────────────────────────────────────────────────"
assert_route "human refine label waits for authorization" none \
  EVENT=issues ACTION=labeled LABEL=refine ACTOR=maintainer EVENT_ISSUE_NUMBER=42
assert_route "bot refine label routes to refine" refine \
  EVENT=issues ACTION=labeled LABEL=refine ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42
assert_route "human implement label waits for authorization" none \
  EVENT=issues ACTION=labeled LABEL=implement ACTOR=maintainer EVENT_ISSUE_NUMBER=42
assert_route "bot implement label routes to implement" implement \
  EVENT=issues ACTION=labeled LABEL=implement ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42
assert_route "human feature label waits for authorization" none \
  EVENT=issues ACTION=labeled LABEL=feature ACTOR=maintainer EVENT_ISSUE_NUMBER=350
assert_route "unrelated label routes nowhere" none \
  EVENT=issues ACTION=labeled LABEL=documentation EVENT_ISSUE_NUMBER=42
assert_route "issue opened without labels routes to triage" triage \
  EVENT=issues ACTION=opened EVENT_ISSUE_NUMBER=42
assert_route "issue opened with refine label skips triage" none \
  EVENT=issues ACTION=opened 'ISSUE_LABELS=["refine"]' EVENT_ISSUE_NUMBER=42
assert_route "issue opened with implement label skips triage" none \
  EVENT=issues ACTION=opened 'ISSUE_LABELS=["implement"]' EVENT_ISSUE_NUMBER=42
assert_route "a human triage label routes to triage" triage \
  EVENT=issues ACTION=labeled LABEL=triage ACTOR=maintainer EVENT_ISSUE_NUMBER=42
assert_route "a bot triage label routes nowhere" none \
  EVENT=issues ACTION=labeled LABEL=triage ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42
assert_route "implement + bot-working without feature routes to implement" implement \
  EVENT=issues ACTION=labeled LABEL=bot-working 'ISSUE_LABELS=["implement","bot-working"]' EVENT_ISSUE_NUMBER=300
assert "refine label starts a first pass" first \
  "$(route_field refine-mode EVENT=issues ACTION=labeled LABEL=refine ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42)"

echo "── Comment events ────────────────────────────────────────────────────────"
assert_route "a comment on a pull request routes to apply-review" apply-review \
  EVENT=issue_comment COMMENT_ON_PR=true EVENT_ISSUE_NUMBER=7
assert_route "the bot's own comment on a pull request never re-enters apply-review" none \
  EVENT=issue_comment COMMENT_ON_PR=true COMMENT_SENDER_TYPE=Bot EVENT_ISSUE_NUMBER=7
assert_route "an author reply on a refine issue re-refines" refine \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User \
  'ISSUE_LABELS=["refine","review"]' EVENT_ISSUE_NUMBER=42
assert "an author reply is a rerefine pass" rerefine \
  "$(route_field refine-mode EVENT=issue_comment COMMENT_ON_PR=false \
    COMMENT_SENDER_TYPE=User 'ISSUE_LABELS=["refine"]' EVENT_ISSUE_NUMBER=42)"
assert_route "the bot's own comment never re-enters refine" none \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=Bot \
  'ISSUE_LABELS=["refine"]' EVENT_ISSUE_NUMBER=42
assert_route "a comment on an issue without refine routes nowhere" none \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User \
  'ISSUE_LABELS=["bug"]' EVENT_ISSUE_NUMBER=42
assert_route "the bot's own comment never re-enters direct" none \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=Bot \
  'ISSUE_LABELS=["direct"]' EVENT_ISSUE_NUMBER=42
assert_route "a comment on a triage issue re-triages" triage \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User \
  'ISSUE_LABELS=["triage"]' EVENT_ISSUE_NUMBER=42
assert "a triage re-trigger is a retriage pass" retriage \
  "$(route_field triage-mode EVENT=issue_comment COMMENT_ON_PR=false \
    COMMENT_SENDER_TYPE=User 'ISSUE_LABELS=["triage"]' EVENT_ISSUE_NUMBER=42)"
assert_route "the bot's own comment never re-enters triage" none \
  EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=Bot \
  'ISSUE_LABELS=["triage"]' EVENT_ISSUE_NUMBER=42

echo "── Closed issues ─────────────────────────────────────────────────────────"
assert_route "a closing comment on a refine issue does not re-refine" none   EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User   ISSUE_STATE=closed 'ISSUE_LABELS=["refine"]' EVENT_ISSUE_NUMBER=42
assert_route "a comment on a closed issue never re-triages" none   EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User   ISSUE_STATE=closed 'ISSUE_LABELS=["triage"]' EVENT_ISSUE_NUMBER=42
assert_route "a work label added to a closed issue routes nowhere" none   EVENT=issues ACTION=labeled LABEL=bot-working ISSUE_STATE=closed   'ISSUE_LABELS=["implement"]' EVENT_ISSUE_NUMBER=42
assert_route "a closed issue reopened as opened still routes nowhere while closed" none   EVENT=issues ACTION=opened ISSUE_STATE=closed 'ISSUE_LABELS=[]' EVENT_ISSUE_NUMBER=42
assert_route "a comment on a closed pull request still routes to apply-review" apply-review   EVENT=issue_comment COMMENT_ON_PR=true ISSUE_STATE=closed EVENT_ISSUE_NUMBER=7
assert_route "an open refine issue is unaffected by the closed guard" refine   EVENT=issue_comment COMMENT_ON_PR=false COMMENT_SENDER_TYPE=User   ISSUE_STATE=open 'ISSUE_LABELS=["refine"]' EVENT_ISSUE_NUMBER=42

echo "── Review events ─────────────────────────────────────────────────────────"
assert_route "a review comment routes to apply-review" apply-review \
  EVENT=pull_request_review_comment EVENT_PR_NUMBER=7
assert_route "a submitted review routes to apply-review" apply-review \
  EVENT=pull_request_review EVENT_PR_NUMBER=7
assert_route "a pull_request_target routes to bot-approve" bot-approve \
  EVENT=pull_request_target ACTION=opened

echo "── CI completion ─────────────────────────────────────────────────────────"
assert_route "a failed App CI run on a pull request routes to merge-gate" merge-gate \
  EVENT=workflow_run RUN_PR_NUMBER=7 RUN_CONCLUSION=failure RUN_ID=99
assert "merge-gate carries the failing CI conclusion" failure \
  "$(route_field ci-conclusion EVENT=workflow_run RUN_PR_NUMBER=7 \
    RUN_CONCLUSION=failure RUN_ID=99)"
assert "merge-gate carries the failing CI run id" 99 \
  "$(route_field ci-run-id EVENT=workflow_run RUN_PR_NUMBER=7 \
    RUN_CONCLUSION=failure RUN_ID=99)"
assert_route "a green App CI run does not auto-trigger the gate" none \
  EVENT=workflow_run RUN_PR_NUMBER=7 RUN_CONCLUSION=success RUN_ID=99
assert_route "a cancelled App CI run does not auto-trigger the gate" none \
  EVENT=workflow_run RUN_PR_NUMBER=7 RUN_CONCLUSION=cancelled RUN_ID=99
assert_route "a failed CI run with no pull request routes nowhere" none \
  EVENT=workflow_run RUN_PR_NUMBER= RUN_CONCLUSION=failure RUN_ID=99

echo "── Schedules ─────────────────────────────────────────────────────────────"
while read -r cron; do
  selected="$(route_field route EVENT=schedule "SCHEDULE=${cron}")"

  if [ "$selected" = "none" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: cron '${cron}' in work-router.yml maps to no route" >&2
  else
    PASS=$((PASS + 1))
    echo "  ${cron} -> ${selected}"
  fi
done < <(sed -n 's/^ *- cron: "\(.*\)"$/\1/p' "$ROUTER_YML")

assert_route "an unknown cron routes nowhere" none EVENT=schedule "SCHEDULE=0 0 30 2 *"

echo "── Manual dispatch ───────────────────────────────────────────────────────"
assert_route "refine dispatch needs an issue number" none \
  EVENT=workflow_dispatch OPERATION=refine INPUT_ISSUE_NUMBER=
assert_route "refine dispatch rejects a non-numeric issue" none \
  EVENT=workflow_dispatch OPERATION=refine INPUT_ISSUE_NUMBER=abc
assert_route "refine dispatch accepts a positive issue" refine \
  EVENT=workflow_dispatch OPERATION=refine INPUT_ISSUE_NUMBER=42
assert_route "direct dispatch needs an issue number" none \
  EVENT=workflow_dispatch OPERATION=direct INPUT_ISSUE_NUMBER=
assert_route "triage dispatch accepts a positive issue" triage \
  EVENT=workflow_dispatch OPERATION=triage INPUT_ISSUE_NUMBER=42
assert_route "triage dispatch needs an issue number" none \
  EVENT=workflow_dispatch OPERATION=triage INPUT_ISSUE_NUMBER=
assert "triage dispatch defaults to first pass" first \
  "$(route_field triage-mode EVENT=workflow_dispatch OPERATION=triage INPUT_ISSUE_NUMBER=42)"
assert_route "batch dispatch needs an issue number" none \
  EVENT=workflow_dispatch OPERATION=batch INPUT_ISSUE_NUMBER=
assert_route "merge-gate dispatch needs a pull request number" none \
  EVENT=workflow_dispatch OPERATION=merge-gate INPUT_PR_NUMBER=0
assert_route "merge-gate dispatch accepts a positive pull request" merge-gate \
  EVENT=workflow_dispatch OPERATION=merge-gate INPUT_PR_NUMBER=7
assert "merge-gate dispatch defaults its attempt count to zero" 0 \
  "$(route_field merge-gate-attempts EVENT=workflow_dispatch OPERATION=merge-gate INPUT_PR_NUMBER=7)"
assert "merge-gate dispatch forwards the attempt count" 3 \
  "$(route_field merge-gate-attempts EVENT=workflow_dispatch OPERATION=merge-gate INPUT_PR_NUMBER=7 INPUT_ATTEMPTS_SO_FAR=3)"
# The implement worker re-dispatches itself when a run dies before producing an answer, so the
# count has to survive the round trip or the budget never advances and the retry never stops.
assert "implement dispatch defaults its attempt count to zero" 0 \
  "$(route_field implement-attempts EVENT=workflow_dispatch OPERATION=implement INPUT_ISSUE_NUMBER=42)"
assert "implement dispatch forwards the attempt count" 2 \
  "$(route_field implement-attempts EVENT=workflow_dispatch OPERATION=implement INPUT_ISSUE_NUMBER=42 INPUT_ATTEMPTS_SO_FAR=2)"
assert "a refine dispatch carries no implement attempts" 0 \
  "$(route_field implement-attempts EVENT=workflow_dispatch OPERATION=refine INPUT_ISSUE_NUMBER=42 INPUT_ATTEMPTS_SO_FAR=2)"
assert_route "reconcile-bot-pr-runs dispatch needs no numbers" reconcile-bot-pr-runs \
  EVENT=workflow_dispatch OPERATION=reconcile-bot-pr-runs
assert_route "an unknown operation routes nowhere" none \
  EVENT=workflow_dispatch OPERATION=deploy-everything
assert "a scheduled audit reports its trigger kind" scheduled \
  "$(route_field trigger-kind EVENT=schedule "SCHEDULE=17 1 * * 1")"

assert "a dispatched audit reports its trigger kind" manual \
  "$(route_field trigger-kind EVENT=workflow_dispatch OPERATION=audit INPUT_TRIGGER_KIND=manual)"

echo "── Local action references ───────────────────────────────────────────────"

# Every `uses: ./.github/actions/x` has to resolve to an action this install wrote. A
# reference to a directory that is not there fails when the job runs and not before, which
# for a scheduled route means at three in the morning with nobody reading. The composite
# verifier checks the actions that exist; this checks the ones that are named.
REFERENCES_OK=1
while IFS= read -r reference; do
  [ -n "$reference" ] || continue
  if [ ! -f "${HERE}/../../../${reference}/action.yml" ]; then
    REFERENCES_OK=0
    echo "FAIL: a workflow uses ./${reference}, which this repository does not have" >&2
  fi
done < <(
  grep -rhoE 'uses: \./\.github/actions/[a-z0-9-]+' \
    "${HERE}/../../workflows"/*.yml "${HERE}/../../workflows"/*.md "${HERE}/../"*/*.yml 2>/dev/null |
    sed 's|uses: \./||' | sort -u
)
if [ "$REFERENCES_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── Forbidden git operations (FR-029) ─────────────────────────────────────"

# Nothing this loop ships deletes a branch, and nothing rebases onto one. A deleted branch
# takes the only copy of an agent's work with it, and the promotion route recreates branches
# on later stages, so a stray deletion removes a change mid-flight. `git rebase --onto` is
# the rewrite a fast-forward-only push discards silently, along with whatever it contained.
# The package asserts this over its own source; this is the same rule over what was actually
# installed, which is what a consumer's CI can see.
FORBIDDEN_OK=1
while IFS= read -r offence; do
  [ -n "$offence" ] || continue
  FORBIDDEN_OK=0
  echo "FAIL: a forbidden git operation is present in an installed file: ${offence}" >&2
done < <(
  # --exclude takes a file name, not a path. Every path here is written relative to this
  # action's own directory, so it contains "verify-route-matrix" whatever file it ends at,
  # and filtering on the path discarded every hit and reported a clean sweep of nothing.
  grep -rnE --exclude=verify-route-matrix.sh -- '--delete-branch|git[[:space:]]+branch[[:space:]]+(-[dD][[:space:]]|--delete)|git[[:space:]]+push[^|]*([[:space:]]--delete|[[:space:]]"?:)|(--method[[:space:]]+DELETE|-X[[:space:]]*DELETE)[^|]*git/refs|git[[:space:]]+rebase[[:space:]]+--onto' \
    "${HERE}/../"*/*.sh "${HERE}/../"*/*.yml "${HERE}/../../workflows"/*.yml "${HERE}/../../workflows"/*.md 2>/dev/null
)
if [ "$FORBIDDEN_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── The gate merges only where the profile allows (FR-035) ────────────────"

# The agent judges the change; whether this repository merges unattended into this
# particular branch is the profile's answer. They used to be one condition: the verdict
# `merge` both merged and cleared the issue's labels, so with auto-merge off the verdict
# alone would strip an open pull request's labels, break the require-label check on a
# re-run, and retire `pr-pending` while the pull request was still pending.
GATE_POLICY_OK=1
if [ ! -f "$MERGE_GATE_WORKER_MD" ]; then
  GATE_POLICY_OK=0
  echo "FAIL: the merge-gate worker is not installed" >&2
else
  # Every step that merges, or takes a step towards merging, asks the policy first.
  for step in "Merge approved pull request" "Check the forge will take the merge" \
    "Arm auto-merge when a rule is holding it" \
    "Refuse a rebase merge whose commits close the issue"; do
    # -e, because a pattern that starts with a dash is read as an option and the error
    # ("unknown option") does not mention the pattern at all.
    condition="$(grep -A 2 -F -e "- name: ${step}" "$MERGE_GATE_WORKER_MD" | grep -m1 -E '^ +if:' || true)"
    case "$condition" in
      *"auto_merge == 'true'"*) ;;
      *)
        GATE_POLICY_OK=0
        echo "FAIL: the merge-gate step '${step}' does not ask whether this base merges unattended; a repository with auto-merge off would merge anyway" >&2
        ;;
    esac
  done

  # And the policy is answered from the profile rather than assumed.
  grep -q 'AUTO_MERGE_MODE: ' "$MERGE_GATE_WORKER_MD" ||
    { GATE_POLICY_OK=0; echo "FAIL: the merge-gate worker declares no AUTO_MERGE_MODE, so its auto_merge output has nothing to read" >&2; }

  # Nothing in the gate retires a label on a verdict. Every post-merge transition belongs to
  # the stage-merge route, which sees the bot's App-token merge as the same closed event a
  # person's merge raises: a transition with two owners happens twice or not at all.
  if grep -q 'name: Clear merged issue labels' "$MERGE_GATE_WORKER_MD"; then
    GATE_POLICY_OK=0
    echo "FAIL: the merge-gate clears the issue's labels itself; the stage-merge route owns every post-merge transition (FR-051)" >&2
  fi

  # The vocabulary the gate can act on has to be the vocabulary its validator accepts,
  # otherwise an approval is thrown away as an invalid verdict.
  VALIDATOR_SH="${HERE}/../validate-merge-gate-output/validate-merge-gate-output.sh"
  if [ -f "$VALIDATOR_SH" ]; then
    grep -q 'approve' "$VALIDATOR_SH" ||
      { GATE_POLICY_OK=0; echo "FAIL: the merge-gate validator does not accept an approve verdict, so a gate that may not merge has no verdict to give" >&2; }
  fi
fi
  # A rule holding a pull request is not a refusal aimed at us, and the loop must neither
  # merge past it nor treat it as the end of the road (FR-080). The forge reports `BLOCKED`
  # to every caller, including one a ruleset would let through, so the gate arms auto-merge
  # and the merge happens when the rule is satisfied.
  grep -qF -e "- name: Arm auto-merge when a rule is holding it" "$MERGE_GATE_WORKER_MD" ||
    { GATE_POLICY_OK=0; echo "FAIL: the merge gate has no arming step, so a protected repository would hand every bot pull request to a person" >&2; }
  grep -q -- '--auto' "$MERGE_GATE_WORKER_MD" ||
    { GATE_POLICY_OK=0; echo "FAIL: the merge gate never arms auto-merge; the deferred path is what merges a pull request a rule is holding" >&2; }
  # And it must not ask to be exempted from the rules it is waiting on.
  if grep -qiE 'bypass_actors|bypass_mode' "$MERGE_GATE_WORKER_MD"; then
    GATE_POLICY_OK=0
    echo "FAIL: the merge gate references a ruleset bypass; this loop merges what the rules allow and never past them" >&2
  fi

if [ "$GATE_POLICY_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── Every scheduled route, both ends (research R7) ────────────────────────"

# A schedule and a classifier are two halves of one route, and they fail apart quietly: a
# cron the classifier does not recognise fires a run that classifies to nothing, reports
# success, and does no work. Nobody notices until somebody asks why the audit has not run
# for a month.
#
# Both ends are projected from one profile entry per route now, so the way to break this is
# to edit one file, which is exactly what this catches.
SCHEDULE_OK=1
mapfile -t ROUTER_CRONS < <(
  tr -d '\r' <"$ROUTER_YML" | sed -n '/^  schedule:/,/^  [a-z_]*:/p' |
    sed -n 's/^    - cron: "\(.*\)".*/\1/p'
)
# A repository with no schedule is a repository whose profile switched every clock off,
# which is a supported answer and not a broken install (FR-081). What must hold either way is
# that the two files agree: a schedule with no constant behind it fires into nothing, and a
# constant with no schedule in front of it says a route runs on a clock that was never
# started. The second is checked below; this is the first.
if [ "${#ROUTER_CRONS[@]}" -eq 0 ]; then
  for name in AUDIT_CRON AUDIT_CLOSE_CRON CLEANUP_ARTIFACTS_CRON RECONCILE_BOT_PR_RUNS_CRON PROMOTE_CRON SYNC_STAGES_CRON; do
    if declare -p "$name" >/dev/null 2>&1 && [ -n "${!name}" ]; then
      SCHEDULE_OK=0
      echo "FAIL: the router runs on no schedule at all, but the classifier still carries ${name}='${!name}'; one of the two files was written from a different profile" >&2
    fi
  done
fi

for cron in "${ROUTER_CRONS[@]}"; do
  # The classifier is already sourced, so its constants are this shell's. A cron the router
  # fires must be one of them, and must reach a route.
  answered=""
  for name in AUDIT_CRON AUDIT_CLOSE_CRON CLEANUP_ARTIFACTS_CRON RECONCILE_BOT_PR_RUNS_CRON PROMOTE_CRON SYNC_STAGES_CRON; do
    declare -p "$name" >/dev/null 2>&1 || continue
    [ "${!name}" = "$cron" ] || continue
    answered="$name"
    break
  done
  if [ -z "$answered" ]; then
    SCHEDULE_OK=0
    echo "FAIL: the router fires at '${cron}' and the classifier has no constant with that value, so the run would classify to no route and report success" >&2
    continue
  fi
  route="$(route_field route EVENT=schedule "SCHEDULE=${cron}")"
  if [ -z "$route" ] || [ "$route" = "none" ]; then
    SCHEDULE_OK=0
    echo "FAIL: the router fires at '${cron}' (${answered}) and the classifier routes it nowhere" >&2
  fi
done

# And the other way: a constant the classifier answers to that no schedule fires is a route
# that can only be reached by hand, which is not what a cron constant says it is.
for name in AUDIT_CRON AUDIT_CLOSE_CRON CLEANUP_ARTIFACTS_CRON RECONCILE_BOT_PR_RUNS_CRON PROMOTE_CRON SYNC_STAGES_CRON; do
  declare -p "$name" >/dev/null 2>&1 || continue
  value="${!name}"
  [ -n "$value" ] || continue
  fired=0
  for cron in "${ROUTER_CRONS[@]}"; do
    [ "$cron" = "$value" ] || continue
    fired=1
    break
  done
  [ "$fired" -eq 1 ] ||
    { SCHEDULE_OK=0; echo "FAIL: the classifier answers to ${name}='${value}' but no schedule in the router fires at it" >&2; }
done
if [ "$SCHEDULE_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── The outcome line (FR-058) ─────────────────────────────────────────────"

# Nothing used to write a step summary and every no-work path exited 0, so a run that did
# nothing and a run that did something looked the same. Two things are asserted here: that
# every deterministic router job still says what it did, and that every reason code in an
# installed file is in the closed enumeration -- a set that grows at the call site is not
# closed, and the point of a closed set is that a reader can enumerate the answers.
OUTCOME_OK=1
OUTCOME_SCRIPT="${HERE}/../record-outcome/record-outcome.sh"

if [ ! -f "$OUTCOME_SCRIPT" ]; then
  OUTCOME_OK=0
  echo "FAIL: the record-outcome action is not installed, so no job can write an outcome line" >&2
else
  # The enumeration, read from the one file that holds it.
  mapfile -t OUTCOME_REASONS < <(
    sed -n '/^readonly REASONS=(/,/^)/p' "$OUTCOME_SCRIPT" |
      sed -e '1d' -e '$d' -e 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d'
  )
  [ "${#OUTCOME_REASONS[@]}" -gt 0 ] ||
    { OUTCOME_OK=0; echo "FAIL: could not read the reason enumeration from record-outcome.sh" >&2; }

  # Every deterministic router job. A caller job (call-*) has no steps of its own; its
  # worker records instead.
  for job in runner-preflight authorize classify check-implement-pr dispatch-triage \
    resolve-merge-base bot-approve detect-pr-conflicts reconcile-bot-pr-runs audit-close cleanup-artifacts validate; do
    block="$(tr -d '\r' <"$ROUTER_YML" | sed -n "/^  ${job}:\$/,/^  [a-z][a-z0-9-]*:\$/p")"
    [ -n "$block" ] || continue
    if ! grep -q 'record-outcome' <<<"$block" && ! grep -q 'outcome=' <<<"$block"; then
      OUTCOME_OK=0
      echo "FAIL: the ${job} job writes no outcome line, so a run in which it did nothing is indistinguishable from one in which it did something" >&2
    fi
  done

  # Every reason literal, wherever it is written. The matrix itself is excluded: it names
  # codes in its own failure messages, and a check that reads its own prose as evidence is
  # not a check.
  while IFS= read -r used; do
    [ -n "$used" ] || continue
    if ! printf '%s\n' "${OUTCOME_REASONS[@]}" | grep -qxF "$used"; then
      OUTCOME_OK=0
      echo "FAIL: reason '${used}' is written in an installed file but is not in the enumeration in record-outcome.sh" >&2
    fi
  done < <(
    {
      # This file is excluded by name, not by filtering its matches: -o prints the match
      # alone, so a `grep -v verify-route-matrix` downstream has no path left to match on
      # and excluded nothing. It went unnoticed while the matrix happened to write no
      # reason literal of its own; the comment below then wrote one, and the check
      # reported it against itself.
      grep -rhoE --exclude='verify-route-matrix.sh' 'reason=[a-z][a-z-]*' "${HERE}/../"*/*.sh "${HERE}/../"*/*.yml "${HERE}/../../workflows"/*.yml "${HERE}/../../workflows"/*.md 2>/dev/null |
        grep -v 'reason=<'
      # A shell file assigns its reason to a variable and hands it over later, so the
      # unquoted pattern above never saw one of them. Both shapes are read here: the
      # promotion route collected eight codes this way, none of them checked against the
      # enumeration until 12/09/2026.
      grep -rhoE --exclude='verify-route-matrix.sh' 'reason="[a-z][a-z-]*"|skipped_because "[a-z][a-z-]*"' "${HERE}/../"*/*.sh 2>/dev/null |
        sed -e 's/^skipped_because //' -e 's/^reason=//' -e 's/"//g' -e 's/^/reason=/'
    } | sed 's/^reason=//' | sort -u
  )
fi
if [ "$OUTCOME_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── The pipeline is invoked unattended (FR-047, FR-071) ───────────────────"

# The kit's pipeline has one mode this caller may use. In every other mode it switches
# branches, stashes, pulls, merges and pushes, none of which this sandbox holds credentials
# for -- and rather than fail at the first of them it refuses up front, when `CI` is set and
# no mode token was passed. A worker that invokes the command without the token therefore
# burns a whole runner and produces nothing, every time, and the only sign of it is one
# refusal line in the agent's log. Three things are asserted on the installed worker: the
# invocation carries the token and the issue-context path, no other mention of the command
# lacks the token, and the identity the pipeline's preconditions demand is declared.
IMPLEMENT_WORKER="${HERE}/../../workflows/agent-implement.md"
if [ ! -f "$IMPLEMENT_WORKER" ]; then
  # A repository that did not select this capability has no implement worker, which is a
  # supported install rather than a failure.
  echo "skip: agent-implement.md is not installed here"
else
  if grep -qF '/${{ env.PLAN_RUN_COMMAND }} unattended ${{ env.ISSUE_CONTEXT_PATH }}' "$IMPLEMENT_WORKER"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: agent-implement.md does not invoke the pipeline as '<command> unattended <issue context path>'" >&2
  fi

  # grep -E has no negative lookahead, so this is two passes: every mention of the command
  # with what follows it, then the ones the token does not follow. The diagram label counts:
  # a reader who copies it into an instruction loses the mode with it.
  bare=$(grep -oE '/\$\{\{ env\.PLAN_RUN_COMMAND \}\}.{0,11}' "$IMPLEMENT_WORKER" | grep -vc ' unattended' || true)
  if [ "${bare:-0}" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: agent-implement.md names the pipeline command ${bare} time(s) without the unattended token" >&2
  fi

  # `Name <email>`: the pipeline reads this when the container carries no git configuration
  # of its own, which is every run, and stops at `identity-missing` when it is absent.
  identity=$(sed -n 's/^  HARNESS_GIT_IDENTITY: "\(.*\)"$/\1/p' "$IMPLEMENT_WORKER")
  case "$identity" in
    *" <"*"@"*">") PASS=$((PASS + 1)) ;;
    *)
      FAIL=$((FAIL + 1))
      echo "FAIL: agent-implement.md declares HARNESS_GIT_IDENTITY as '${identity}', which is not 'Name <email>'" >&2
      ;;
  esac
fi

echo "── Safe-output overrides (FR-052) ────────────────────────────────────────"

# The compiler returns an empty handler configuration on any parse failure and still
# succeeds, so the frontmatter proves only that somebody wrote the override: a mistyped
# key ships every default and nothing is red. What a run reads is the compiled lock, and
# it reads two copies of it -- the MCP server's and the conclude handler's. An override
# present in one and not the other is a run that behaves one way while proposing the pull
# request and another way writing it, so both are checked.
OVERRIDES_OK=1
overrides_checked=0
overrides_locks=0

# Both copies, unescaped back into JSON. The lock writes them as one double-quoted YAML
# scalar per line.
lock_handler_configs() {
  sed -n \
    -e 's/^ *GH_AW_SAFE_OUTPUTS_CONFIG: "\(.*\)"$/\1/p' \
    -e 's/^ *GH_AW_SAFE_OUTPUTS_HANDLER_CONFIG: "\(.*\)"$/\1/p' \
    "$1" | sed 's/\\"/"/g'
}

for lock in "${HERE}/../../workflows"/agent-*.lock.yml; do
  [ -f "$lock" ] || continue
  overrides_locks=$((overrides_locks + 1))
  worker="${lock%.lock.yml}.md"
  # The base the worker declares, so the two halves of one projection are compared
  # against each other rather than against a profile the matrix cannot see (FR-042).
  declared_base=""
  if [ -f "$worker" ]; then
    declared_base="$(sed -n 's/^  BASE_BRANCH: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$worker" | head -n1)"
  fi

  while IFS= read -r config; do
    [ -n "$config" ] || continue
    overrides_checked=$((overrides_checked + 1))

    if ! printf '%s' "$config" | jq -e '
      if has("create_pull_request") then
        .create_pull_request
        | .signed_commits == false
          and .auto_close_issue == false
          and .preserve_branch_name == true
          and .fallback_as_issue == false
          and (.base_branch | type == "string" and length > 0)
          and (has("allowed_base_branches") | not)
          and (has("recreate_ref") | not)
          and ((has("patch_format") | not) or .patch_format == "bundle")
          and (.branch_prefix | type == "string" and length > 0 and (test("[{](issue|run)[}]") | not))
      else true end' >/dev/null 2>&1; then
      OVERRIDES_OK=0
      echo "FAIL: $(basename "$lock") carries a create_pull_request configuration that is not FR-052's: it must set signed_commits, auto_close_issue and fallback_as_issue false, preserve_branch_name true, a base_branch and an expanded branch_prefix, and carry no allowed_base_branches, no recreate_ref and no patch_format other than bundle" >&2
    fi

    # Only where the handler is the thing that pushes. A staged worker's safe outputs are
    # written by its own conclude job with the App token, so the handler's fallbacks never
    # run and requiring the settings there would be a rule with no failure behind it.
    if ! grep -qE '^  staged: true' "$worker" 2>/dev/null; then
      if ! printf '%s' "$config" | jq -e '
        if has("push_to_pull_request_branch") then
          .push_to_pull_request_branch
          | .signed_commits == false
            and .fallback_as_pull_request == false
            and .check_branch_protection == false
        else true end' >/dev/null 2>&1; then
        OVERRIDES_OK=0
        echo "FAIL: $(basename "$lock") pushes unstaged and lets the pull-request-branch handler keep a default: signed_commits, fallback_as_pull_request and check_branch_protection must all be false" >&2
      fi
    fi

    if [ -n "$declared_base" ]; then
      lock_base="$(printf '%s' "$config" | jq -r 'if has("create_pull_request") then (.create_pull_request.base_branch // "") else "" end' 2>/dev/null)"
      if [ -n "$lock_base" ] && [ "$lock_base" != "$declared_base" ]; then
        OVERRIDES_OK=0
        echo "FAIL: $(basename "$lock") opens against '${lock_base}' while $(basename "$worker") tells the agent '${declared_base}'" >&2
      fi
    fi
  done < <(lock_handler_configs "$lock")
done

echo "  ${overrides_checked} handler configuration(s) in ${overrides_locks} compiled lock(s)"
# No PASS is counted when nothing was checked: a repository whose workers are not
# compiled has not passed this, it has not run it.
if [ "$overrides_checked" -gt 0 ]; then
  if [ "$OVERRIDES_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
fi

echo "── Branching strategy ────────────────────────────────────────────────────"

# The router executes this matrix at run time from installed files alone; there is no profile
# in a consumer repository to read (FR-042). The strategy, its stages, the branch changes are
# cut from and the branch they close on are therefore read from the classifier itself, where
# the projector writes them as constants beside the crons: BRANCH_STRATEGY, STAGE_BRANCHES,
# CUT_FROM, CLOSE_ISSUE_ON and RELEASE_PATTERN (contracts/projection.md, FR-051). Sourcing
# classify-route.sh above brought them into scope. An installed copy that carries none of them
# has not been projected, and every row below would compare against an empty string and agree.
STRATEGY_OK=1
STAGE_COUNT=0
if declare -p STAGE_BRANCHES >/dev/null 2>&1; then STAGE_COUNT="${#STAGE_BRANCHES[@]}"; fi
if [ -z "${BRANCH_STRATEGY:-}" ] || [ "$STAGE_COUNT" -eq 0 ] ||
  [ -z "${CUT_FROM:-}" ] || [ -z "${CLOSE_ISSUE_ON:-}" ]; then
  STRATEGY_OK=0
  echo "FAIL: the installed classifier carries no BRANCH_STRATEGY, STAGE_BRANCHES, CUT_FROM or CLOSE_ISSUE_ON constant, so no strategy row can be evaluated" >&2
fi

if [ "$STRATEGY_OK" -eq 1 ]; then
  case "$BRANCH_STRATEGY" in
    trunk)
      # Nowhere to promote to: one stage, which is both the branch changes are cut from and
      # the branch they close on, and no promote cron, dispatch or job anywhere.
      [ "$STAGE_COUNT" -eq 1 ] ||
        { STRATEGY_OK=0; echo "FAIL: trunk declares ${STAGE_COUNT} stages; it has exactly one" >&2; }
      [ "${STAGE_BRANCHES[0]}" = "$CUT_FROM" ] ||
        { STRATEGY_OK=0; echo "FAIL: trunk's single stage '${STAGE_BRANCHES[0]}' is not the branch changes are cut from ('${CUT_FROM}')" >&2; }
      [ "$CLOSE_ISSUE_ON" = "$CUT_FROM" ] ||
        { STRATEGY_OK=0; echo "FAIL: trunk closes issues on '${CLOSE_ISSUE_ON}', which is not its trunk '${CUT_FROM}'" >&2; }
      if declare -p PROMOTE_CRON >/dev/null 2>&1; then
        STRATEGY_OK=0
        echo "FAIL: trunk carries a promote cron; there is no later stage to promote a change into" >&2
      fi
      # The job itself stays: projection removes lines, not jobs. What matters is that
      # nothing can reach it, which is the cron above and the dispatch below.
      assert_route "a promote dispatch under trunk routes nowhere" none \
        EVENT=workflow_dispatch OPERATION=promote
      if declare -p SYNC_STAGES_CRON >/dev/null 2>&1; then
        STRATEGY_OK=0
        echo "FAIL: trunk carries a sync-stages cron; with one branch there is no stage that can fall behind another" >&2
      fi
      assert_route "a sync-stages dispatch under trunk routes nowhere" none \
        EVENT=workflow_dispatch OPERATION=sync-stages
      ;;
    branch-chain | env-promotion)
      # A chain, a promotion schedule, and a deterministic job named `promote`, never
      # `call-promote`: that prefix is reserved for callers with an inner agent job and the
      # metrics match on it.
      [ "$STAGE_COUNT" -ge 2 ] ||
        { STRATEGY_OK=0; echo "FAIL: branch-chain declares ${STAGE_COUNT} stage(s); a chain has at least two" >&2; }
      closing_is_a_stage=0
      for stage in "${STAGE_BRANCHES[@]}"; do
        if [ "$stage" = "$CLOSE_ISSUE_ON" ]; then closing_is_a_stage=1; fi
      done
      [ "$closing_is_a_stage" -eq 1 ] ||
        { STRATEGY_OK=0; echo "FAIL: issues close on '${CLOSE_ISSUE_ON}', which is not one of the chain's stages" >&2; }
      # No assertion that the promotion clock exists: a chain repository may run promotion by
      # dispatch alone, which is what the canary did while it was being proven and what
      # `crons.promote: off` now expresses as a profile value rather than a local edit
      # (FR-081). What is asserted is that the route is reachable, below, and that a clock
      # which does exist routes to it.
      if grep -q '^  call-promote:' "$ROUTER_YML"; then
        STRATEGY_OK=0
        echo "FAIL: the promote job is named call-promote; that prefix is reserved for worker callers and the metrics match on it" >&2
      fi
      grep -q '^  promote:$' "$ROUTER_YML" ||
        { STRATEGY_OK=0; echo "FAIL: work-router.yml has no promote job" >&2; }
      # A chain that only ever hears about a rollback when somebody remembers the label will
      # carry a reverted change onto the next stage within the hour. git writes the answer
      # into the revert it makes, so the route has to be reading it (FR-053).
      PROMOTE_SCRIPT="${HERE}/../promote-change/promote-change.sh"
      if [ ! -f "$PROMOTE_SCRIPT" ]; then
        STRATEGY_OK=0
        echo "FAIL: this repository promotes along a chain but the promote-change action is not installed" >&2
      else
        grep -q 'This reverts commit' "$PROMOTE_SCRIPT" ||
          { STRATEGY_OK=0; echo "FAIL: the promotion route never reads a revert trailer, so a rollback nobody labelled would be promoted onwards" >&2; }
        grep -q 'was_rolled_back "\$previous"' "$PROMOTE_SCRIPT" ||
          { STRATEGY_OK=0; echo "FAIL: the promotion route can detect a rollback but does not ask before promoting" >&2; }
      fi
      assert_route "a promote dispatch routes to promote" promote \
        EVENT=workflow_dispatch OPERATION=promote
      if declare -p PROMOTE_CRON >/dev/null 2>&1; then
        assert_route "the promote cron routes to promote" promote \
          EVENT=schedule "SCHEDULE=${PROMOTE_CRON}"
      fi
      # The chain's other direction. A stage that falls behind is invisible until a pull
      # request into it carries the whole delta, trips the protected-files rule and skips
      # the model, so the route that carries content back down is not optional equipment on
      # a chain (FR-079).
      # Likewise the back-propagation clock. `doctor`'s stage-alignment check answers the same
      # question from a working copy, so a repository that dispatches it by hand is not blind
      # to a stage falling behind.
      grep -q '^  sync-stages:$' "$ROUTER_YML" ||
        { STRATEGY_OK=0; echo "FAIL: work-router.yml has no sync-stages job" >&2; }
      SYNC_SCRIPT="${HERE}/../sync-stages/sync-stages.sh"
      if [ ! -f "$SYNC_SCRIPT" ]; then
        STRATEGY_OK=0
        echo "FAIL: this repository promotes along a chain but the sync-stages action is not installed" >&2
      else
        # The whole route turns on comparing by content: under a rebase promotion every
        # change that went up the chain has a different sha on each stage, so a sha
        # comparison would report all of them missing and carry the chain back down on its
        # first run.
        grep -q 'git patch-id --stable' "$SYNC_SCRIPT" ||
          { STRATEGY_OK=0; echo "FAIL: the sync-stages route does not compare by patch-id, so it cannot tell a stage that is behind from one that rebased" >&2; }
        grep -q 'gh pr create' "$SYNC_SCRIPT" ||
          { STRATEGY_OK=0; echo "FAIL: the sync-stages route does not open a pull request; a stage may only be written through one" >&2; }
        # Every push it makes is to its own `sync/` head. A push that named a stage would be
        # this route writing a protected branch directly, which is the one thing its design
        # rules out.
        if grep -E '^\s*git push' "$SYNC_SCRIPT" | grep -qvE 'refs/heads/\$\{sync_branch\}'; then
          STRATEGY_OK=0
          echo "FAIL: the sync-stages route pushes something other than its own sync branch; back-propagation goes through a pull request so it gets CI and the gate" >&2
        fi
      fi
      assert_route "a sync-stages dispatch routes to sync-stages" sync-stages \
        EVENT=workflow_dispatch OPERATION=sync-stages
      if declare -p SYNC_STAGES_CRON >/dev/null 2>&1; then
        assert_route "the sync-stages cron routes to sync-stages" sync-stages \
          EVENT=schedule "SCHEDULE=${SYNC_STAGES_CRON}"
      fi

      # Everything above is shared with env-promotion, which is a chain by every other
      # measure. What separates it is how a promotion head is built, and that is what the
      # rest of this arm checks: a snapshot of the stage below, carrying a set of changes
      # rather than one, with no cherry-pick anywhere near it (FR-031, FR-056).
      if [ "$BRANCH_STRATEGY" = "env-promotion" ]; then
        if [ -f "$PROMOTE_SCRIPT" ]; then
          grep -q 'promote_by_snapshot' "$PROMOTE_SCRIPT" ||
            { STRATEGY_OK=0; echo "FAIL: this repository promotes by snapshot but the promotion route has no snapshot path, so it would try to cherry-pick a change onto the next stage" >&2; }
          # The head is a new branch at one commit, and a force-push is the one thing that
          # would make it a moving target again: a reviewer would be approving a head that
          # had changed under them.
          if grep -E '^\s*git push' "$PROMOTE_SCRIPT" | grep -q 'force'; then
            grep -q 'git push origin "HEAD:refs/heads/${snapshot_branch}"' "$PROMOTE_SCRIPT" ||
              { STRATEGY_OK=0; echo "FAIL: the snapshot head is force-pushed; a promotion head that can move is one a person cannot have reviewed" >&2; }
          fi
          # A snapshot carries everything under its commit, so one issue is never the whole
          # answer: the route writes one marker per carried issue and FR-051 reads them all.
          grep -q 'issues_behind' "$PROMOTE_SCRIPT" ||
            { STRATEGY_OK=0; echo "FAIL: the promotion route does not enumerate the issues a snapshot carries, so a promotion would be labelled and closed for one of them" >&2; }
        fi
        # The name the snapshot takes has to be one the branch-write guard allows, or the
        # route refuses its own head on every run and nothing ever promotes (FR-063).
        SNAPSHOT_TEMPLATE="promote/{stage}-{sha}"
        case "$SNAPSHOT_TEMPLATE" in
          promote/*) ;;
          *)
            STRATEGY_OK=0
            echo "FAIL: the snapshot head template '${SNAPSHOT_TEMPLATE}' is not a promotion branch, so the branch-write guard would refuse every promotion this repository tried to open" >&2
            ;;
        esac
        # The gate runs on a promotion pull request although it has no single issue, and it
        # can only do that if the subject reads the marker set (FR-056).
        GATE_SUBJECT="${HERE}/../identify-gate-subject/action.yml"
        if [ -f "$GATE_SUBJECT" ]; then
          grep -q 'pr_issues' "$GATE_SUBJECT" ||
            { STRATEGY_OK=0; echo "FAIL: the gate subject reads one issue, so a promotion pull request carrying several would be gated against the first of them" >&2; }
          grep -q 'comment-target=' "$GATE_SUBJECT" ||
            { STRATEGY_OK=0; echo "FAIL: the gate subject names no comment target, so a promotion's assessment would be posted on one of the issues it carries" >&2; }
        fi
      fi
      ;;
    release-branch)
      # No chain, so no stage to promote into: one stage, which is the trunk, and it is
      # where a change ends however it travelled -- a hotfix goes to a release branch first
      # and is carried back, so the trunk is still the closing stage (FR-055).
      [ "$STAGE_COUNT" -eq 1 ] ||
        { STRATEGY_OK=0; echo "FAIL: release-branch declares ${STAGE_COUNT} stages; it has one, its trunk, and cuts release branches from it" >&2; }
      [ "${STAGE_BRANCHES[0]}" = "$CUT_FROM" ] ||
        { STRATEGY_OK=0; echo "FAIL: release-branch's single stage '${STAGE_BRANCHES[0]}' is not its trunk ('${CUT_FROM}')" >&2; }
      [ "$CLOSE_ISSUE_ON" = "$CUT_FROM" ] ||
        { STRATEGY_OK=0; echo "FAIL: release-branch closes issues on '${CLOSE_ISSUE_ON}', which is not its trunk '${CUT_FROM}'; a hotfix is carried back, so every change ends on the trunk" >&2; }

      # The pattern is what makes a release branch a stage, so a merge into one is a
      # transition rather than somebody's own branch. As an extended regular expression: the
      # classifier, the write guard and the carry-back all feed it to `grep -E`, and a name
      # template handed to `grep -E` is a rule that silently matches nothing.
      if [ -z "${RELEASE_PATTERN:-}" ]; then
        STRATEGY_OK=0
        echo "FAIL: this repository cuts release branches but the classifier carries no RELEASE_PATTERN, so a merge into one would be nobody's business and the issue would never close" >&2
      else
        case "$RELEASE_PATTERN" in
          *'{'*'}'*)
            STRATEGY_OK=0
            echo "FAIL: RELEASE_PATTERN is '${RELEASE_PATTERN}', which is a name template rather than an expression; every reader feeds it to grep -E, where it matches no release branch this repository would ever cut" >&2
            ;;
        esac
      fi

      # The promote route still exists here, and it is what cuts the next release branch on
      # the cadence. Without its clock the strategy has no mechanism at all.
      grep -q '^  promote:$' "$ROUTER_YML" ||
        { STRATEGY_OK=0; echo "FAIL: work-router.yml has no promote job; under release-branch that is the route that cuts the release branch" >&2; }
      assert_route "a promote dispatch routes to promote" promote \
        EVENT=workflow_dispatch OPERATION=promote
      PROMOTE_SCRIPT="${HERE}/../promote-change/promote-change.sh"
      if [ -f "$PROMOTE_SCRIPT" ]; then
        grep -q 'cut_release_branch' "$PROMOTE_SCRIPT" ||
          { STRATEGY_OK=0; echo "FAIL: the promotion route has no release-cutting path, so this repository's release branches would only ever be cut by hand" >&2; }
      fi

      # A hotfix that lands on the release branch and not on the trunk is lost at the next
      # cut, which is the one failure this strategy has that the others do not.
      grep -q '^  hotfix-back:$' "$ROUTER_YML" ||
        { STRATEGY_OK=0; echo "FAIL: work-router.yml has no hotfix-back job, so a hotfix would stay on its release branch and vanish at the next cut" >&2; }

      # Nothing to hold level: the release branches are meant to diverge from the trunk, and
      # a route that carried the trunk back down onto them would undo every release.
      if declare -p SYNC_STAGES_CRON >/dev/null 2>&1; then
        STRATEGY_OK=0
        echo "FAIL: release-branch carries a sync-stages cron; its release branches are meant to diverge from the trunk and a carry-down would undo them" >&2
      fi
      assert_route "a sync-stages dispatch under release-branch routes nowhere" none \
        EVENT=workflow_dispatch OPERATION=sync-stages
      ;;
    *)
      STRATEGY_OK=0
      echo "FAIL: the classifier declares an unknown branching strategy '${BRANCH_STRATEGY}'" >&2
      ;;
  esac
  # The landing wait holds the one global implement slot for up to ninety minutes so the
  # next change branches from a trunk that already contains this one (FR-054). That reason
  # exists under trunk and nowhere else: under a chain the work is cut from the branch point
  # and opens against the first stage, so every implement in the queue would be waiting on a
  # pull request whose landing buys the next one nothing.
  if [ -f "$IMPLEMENT_WORKER_MD" ] && grep -q '^  await_landing:' "$IMPLEMENT_WORKER_MD" &&
    [ "$BRANCH_STRATEGY" != "trunk" ]; then
    STRATEGY_OK=0
    echo "FAIL: the implement worker waits for its pull request to land under '${BRANCH_STRATEGY}', which would stall the whole implement queue on a merge that buys the next change nothing" >&2
  fi
fi

if [ "$STRATEGY_OK" -eq 1 ]; then
  # One row set per stage: the shell's answer to it.each. Every merge into a stage belongs to
  # the stage-merge route, bot or human, because that route owns every post-merge transition.
  # A close without a merge is the same route (it holds a promotion, or releases a first-stage
  # pull request), and a base that is nobody's stage stays with the approval route.
  for stage in "${STAGE_BRANCHES[@]}"; do
    assert_route "a merge into stage '${stage}' routes to stage-merge" stage-merge \
      EVENT=pull_request_target ACTION=closed PR_MERGED=true PR_BASE_REF="$stage" EVENT_PR_NUMBER=7
    assert_route "a pull request closed unmerged on stage '${stage}' routes to stage-merge" stage-merge \
      EVENT=pull_request_target ACTION=closed PR_MERGED=false PR_BASE_REF="$stage" EVENT_PR_NUMBER=7
    assert "stage-merge on '${stage}' carries the pull request number" 7 \
      "$(route_field pr-number EVENT=pull_request_target ACTION=closed PR_MERGED=true \
        PR_BASE_REF="$stage" EVENT_PR_NUMBER=7)"

    # The closing stage ends the change's life. Every earlier stage is a step on the way there
    # and must leave the issue open, or the first promotion closes the work it is promoting.
    if [ "$stage" = "$CLOSE_ISSUE_ON" ]; then
      assert "a merge into the closing stage '${stage}' closes the issue" true \
        "$(route_field closes-issue EVENT=pull_request_target ACTION=closed PR_MERGED=true \
          PR_BASE_REF="$stage" EVENT_PR_NUMBER=7)"
      assert "a close without a merge on '${stage}' closes nothing" false \
        "$(route_field closes-issue EVENT=pull_request_target ACTION=closed PR_MERGED=false \
          PR_BASE_REF="$stage" EVENT_PR_NUMBER=7)"
    else
      assert "a merge into stage '${stage}' leaves the issue open" false \
        "$(route_field closes-issue EVENT=pull_request_target ACTION=closed PR_MERGED=true \
          PR_BASE_REF="$stage" EVENT_PR_NUMBER=7)"
    fi
  done

  MERGED_STAGE_LABEL_FOR_TEST="$(printf '%s' "merged-{stage}" | sed "s/{stage}/${STAGE_BRANCHES[0]}/")"
  # The route writes labels with the plain workflow token, and a label event re-enters the
  # router. These rows are why that is safe: the merged-stage label starts nothing, and
  # clearing the in-flight labels starts nothing either. A label that did route would make
  # every merge a loop.
  assert_route "the merged-stage label this route writes starts nothing" none \
    EVENT=issues ACTION=labeled "LABEL=${MERGED_STAGE_LABEL_FOR_TEST}" ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42
  assert_route "clearing the implement label starts nothing" none \
    EVENT=issues ACTION=unlabeled LABEL=implement ACTOR=personalcorpacc-agentic-loop[bot] EVENT_ISSUE_NUMBER=42

  assert_route "a merge into a branch that is no stage stays with the approval route" bot-approve \
    EVENT=pull_request_target ACTION=closed PR_MERGED=true PR_BASE_REF=chore/not-a-stage EVENT_PR_NUMBER=7
  assert_route "an opened pull request is still the approval route's" bot-approve \
    EVENT=pull_request_target ACTION=opened PR_BASE_REF="${STAGE_BRANCHES[0]}" EVENT_PR_NUMBER=7
  assert_route "a merge-gate label on a stage pull request still routes to merge-gate" merge-gate \
    EVENT=pull_request_target ACTION=labeled LABEL=merge-gate PR_BASE_REF="${STAGE_BRANCHES[0]}" EVENT_PR_NUMBER=7
fi
if [ "$STRATEGY_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# promote and stage-merge are deterministic router jobs, not workers, so the worker rule below
# does not reach them, and they read projected branching values. A name a step prints that the
# job does not define renders empty, and a promotion into "" is what that buys.
# sync-stages is the third of them (FR-079).
JOB_ENV_OK=1
for job in promote stage-merge sync-stages; do
  job_block="$(tr -d '\r' <"$ROUTER_YML" | sed -n "/^  ${job}:\$/,/^  [a-z][a-z0-9-]*:\$/p")"
  [ -n "$job_block" ] || continue
  while read -r name; do
    [ -n "$name" ] || continue
    if ! grep -qE "^ +${name}:" <<<"$job_block"; then
      JOB_ENV_OK=0
      echo "FAIL: the ${job} job prints env.${name} without defining it" >&2
    fi
  done < <(grep -oE '\$\{\{ *env\.[A-Za-z_][A-Za-z0-9_]* *\}\}' <<<"$job_block" |
    sed -E 's/.*env\.([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u)
done
if [ "$JOB_ENV_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "── Router wiring ─────────────────────────────────────────────────────────"

# GitHub evaluates every Actions expression in a workflow file, including ones written inside
# shell comments. An empty pair is not a valid expression and fails the whole file to parse,
# with an error that points at a line number rather than saying what is wrong. Prose about
# expressions must not contain one.
empty_expr=$(grep -rl -e '${{[[:space:]]*}}' "${HERE}/../../workflows"/*.yml "${HERE}/../../workflows"/*.md 2>/dev/null || true)
if [ -z "$empty_expr" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: workflow files contain an empty Actions expression:" >&2
  while IFS= read -r offending; do echo "  $offending" >&2; done <<<"$empty_expr"
fi


# A hyphen inside a ${{ }} property path is parsed as subtraction, so the reference silently
# resolves to nothing and the rendered prompt keeps the raw expression. Underscores only.
if ! grep -qE 'needs\.[a-z_]+\.outputs\.[a-zA-Z0-9_]*-' "$IMPLEMENT_WORKER_MD"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: implement worker reads a hyphenated job output inside an expression" >&2
  grep -nE 'needs\.[a-z_]+\.outputs\.[a-zA-Z0-9_]*-' "$IMPLEMENT_WORKER_MD" >&2
fi

# A worker that prints `${{ env.NAME }}` without defining NAME in its own env: block renders
# an empty value, and the model fills the gap itself. That is how a child shipped `dotnet build
# --no-restore` against an unrestored workspace: the verification block was empty. Every name a
# worker prints must be defined in that worker. The values are consumer-owned (a consumer may
# split VERIFY_COMMANDS per area, or keep one); only the wiring is asserted here.
VERIFY_OK=1
for worker in "${HERE}/../../workflows"/agent-*.md; do
  while read -r name; do
    [ -n "$name" ] || continue
    if ! grep -q "^  ${name}:" "$worker"; then
      VERIFY_OK=0
      echo "FAIL: $(basename "$worker") prints env.${name} without defining it" >&2
    fi
  done < <(grep -oE '\$\{\{ *env\.[A-Za-z_][A-Za-z0-9_]* *\}\}' "$worker" | sed -E 's/.*env\.([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u)
done
if [ "$VERIFY_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# A row about two workers has nothing to assert in a repository that installed
# neither; the exclusion check covers their absence (FR-042).
if [ -f "$IMPLEMENT_WORKER_MD" ] && [ -f "$MERGE_GATE_WORKER_MD" ]; then
  if grep -Fq 'protected-files: allowed' "$IMPLEMENT_WORKER_MD" &&
    grep -Fq 'protected-files: allowed' "$MERGE_GATE_WORKER_MD" &&
    grep -Fq "needs.protected_changes.outputs.requires_review != 'true' || needs.subject.outputs.conclusion == 'failure'" "$MERGE_GATE_WORKER_MD"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: protected changes must allow failed-CI repair while remaining held from merge" >&2
  fi
fi

# gh-aw folds the worker's top-level `if:` into the generated activation job but computes
# activation's `needs` on its own: only custom jobs the prompt references AND that declare no
# `needs:` are hoisted. A guard with its own `needs:` (protected_changes needs subject) is read
# before it has run, resolves to '' and gates nothing, unless it is listed in `on.needs`, the
# documented way to add jobs to pre_activation and activation. Inline list form is expected.
TOP_IF="$(tr -d '\r' <"$MERGE_GATE_WORKER_MD" | sed -n 's/^if: //p')"
ON_NEEDS="$(tr -d '\r' <"$MERGE_GATE_WORKER_MD" | sed -n '/^on:$/,/^[a-z]/p' |
  sed -n 's/^  needs: *\[\(.*\)\].*/\1/p' | tr -d ' ' | tr ',' '\n')"
ACTIVATION_OK=1
[ -n "$TOP_IF" ] || { ACTIVATION_OK=0; echo "FAIL: could not read the merge-gate worker's top-level if" >&2; }
while read -r job; do
  [ -n "$job" ] || continue
  if tr -d '\r' <"$MERGE_GATE_WORKER_MD" | sed -n "/^  ${job}:$/,/^  [a-z_]*:$/p" | grep -q '^    needs:' &&
    ! grep -qx "$job" <<<"$ON_NEEDS"; then
    ACTIVATION_OK=0
    echo "FAIL: merge-gate top-level if reads needs.${job}, which has its own needs and is not in on.needs; activation would read it before it runs" >&2
  fi
done < <(grep -oE 'needs\.[a-z_]+\.' <<<"$TOP_IF" | sed 's/^needs\.//; s/\.$//' | sort -u)
if [ "$ACTIVATION_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# The merge belt is serial per branch work lands on: several overnight pull requests into
# one branch mean every merge moves it under the rest, and gates running at once rebase onto
# bases other gates are about to invalidate. A per-issue group would reintroduce that race;
# a key that is one constant for the whole repository makes a promotion into a later stage
# queue behind feature work into an earlier one (FR-033). Both are asserted, and so is the
# job that resolves the base, because a key naming a job that does not exist is an empty key
# and an empty key is the repository-wide belt again.
BELT_KEY="$(grep -A9 '^  call-merge-gate:' "$ROUTER_YML" | grep -E '^ +group:' | head -n1)"
BELT_LOCK_OK=1
case "$BELT_KEY" in
  *"group: merge-belt-"*) ;;
  *) BELT_LOCK_OK=0; echo "FAIL: call-merge-gate must hold a merge-belt lock keyed on the target branch, not '${BELT_KEY# }'" >&2 ;;
esac
case "$BELT_KEY" in
  *'needs.resolve-merge-base.outputs.base'*) ;;
  *) BELT_LOCK_OK=0; echo "FAIL: the merge belt's key must come from the job that resolves the pull request's base" >&2 ;;
esac
grep -q '^  resolve-merge-base:$' "$ROUTER_YML" ||
  { BELT_LOCK_OK=0; echo "FAIL: work-router.yml has no resolve-merge-base job, so the belt's key would be empty and every gate would share one queue" >&2; }
grep -A3 '^  call-merge-gate:$' "$ROUTER_YML" | grep -q 'needs: \[classify, resolve-merge-base\]' ||
  { BELT_LOCK_OK=0; echo "FAIL: call-merge-gate must need resolve-merge-base, or its key reads an output that was never produced" >&2; }
if [ "$BELT_LOCK_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# A merge moves one branch, so the rescan that follows it asks about that branch. Without
# the filter every open bot pull request is polled for mergeability on every merge -- six
# reads each, five seconds apart -- and a chain dispatches gates for pull requests built on
# a tip that did not move (FR-037).
RESCAN_OK=1
if grep -q 'state=open&per_page=100' "$ROUTER_YML"; then
  grep -q 'select(.user.type == "Bot" and .draft == false and .base.ref == env.MERGED_BASE)' "$ROUTER_YML" ||
    { RESCAN_OK=0; echo "FAIL: the conflict rescan does not filter by the branch that moved, so one merge rescans every open bot pull request" >&2; }
  grep -q 'MERGED_BASE: ${{ github.event.pull_request.base.ref }}' "$ROUTER_YML" ||
    { RESCAN_OK=0; echo "FAIL: the conflict rescan filters on MERGED_BASE but nothing sets it, so the filter matches nothing" >&2; }
fi
if [ "$RESCAN_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# A verdict is the gate marker AND a `**Verdict:**` line together. Comments carrying the
# marker alone were progress notes and failed attempts, and the reconcile belt read every
# one of them as final: a crashed or OOM-killed gate parked its pull request for the rest
# of the night. Attempts are counted separately, capped, and reset by any new CI run.
BELT_OK=1
if ! grep -q 'agent-merge-gate-attempt' "$ROUTER_YML"; then
  BELT_OK=0; echo "FAIL: router never counts gate attempts" >&2
fi
if [ "$(grep -cF 'contains("<!-- agent-merge-gate -->")) and (.body | contains("**Verdict:**"))' "$ROUTER_YML")" -lt 4 ]; then
  BELT_OK=0; echo "FAIL: verdict detection must pair the gate marker with a Verdict line in both dispatch paths" >&2
fi
if [ "$(grep -c 'attempts_so_far' "$ROUTER_YML")" -lt 2 ]; then
  BELT_OK=0; echo "FAIL: dispatch sites must forward attempts_so_far" >&2
fi
# A second gate for a pull request whose gate is already queued or running reads the same CI
# verdict and is cancelled by the single-slot merge-belt queue (two cancellations on 2026-09-06).
if [ "$(grep -c 'a merge-gate run is already live' "$ROUTER_YML")" -lt 2 ]; then
  BELT_OK=0; echo "FAIL: both dispatch paths must skip a pull request whose gate is already live" >&2
fi
# A conflicting pull request has no refs/pull/N/merge for GitHub to build, so a `pull_request`
# CI workflow can never run on that head. Requiring a fresh verdict before dispatching deadlocks
# the belt: only the gate resolves the conflict, and the gate never runs. Both paths fall back to
# the branch's last verdict when, and only when, the pull request is conflicting.
if [ "$(grep -c 'conflicts, so CI cannot run on' "$ROUTER_YML")" -lt 2 ]; then
  BELT_OK=0
  echo "FAIL: both dispatch paths must gate a conflicting pull request that can never get fresh CI" >&2
fi
# That fallback has to read the computed mergeable state. The REST boolean is null until GitHub
# recomputes it, and stays null for a pull request nobody has opened recently, which is exactly
# the stale conflicting pull request the fallback exists for: it never fired once in production.
# The state has to be polled, not read once. GitHub computes mergeability on demand and the
# first read answers UNKNOWN (or null through REST) while it works it out, so a single read
# reports "not conflicting" for exactly the stale pull requests the fallback is for. Observed
# twice in production: the fallback logged "no completed CI run" for a pull request that
# `gh pr view` reported as CONFLICTING from a warm cache seconds later.
if [ "$(grep -c 'mergeable_state()' "$ROUTER_YML")" -lt 2 ] ||
  [ "$(grep -c 'mergeable_now=$(mergeable_state' "$ROUTER_YML")" -lt 2 ]; then
  BELT_OK=0
  echo "FAIL: both dispatch paths must poll the mergeable state; a single read answers UNKNOWN" >&2
fi
if [ "$BELT_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# GitHub delivers workflow_run only for CI runs whose actor is a human, so a bot pull request's
# CI never reaches the router's CI-completion route. The package ships a dispatch-merge-gate job
# in templates/ci that hands the verdict over from inside CI; a consumer CI workflow, where one
# exists beside the router, must carry it or bot pull requests wait for the hourly belt. The
# job calls the dispatch-merge-gate composite, so that reference is what a template carries; an
# older consumer copy may still hold the inlined step, and both count.
for ci in "${HERE}/../../workflows/ci.yml" "${HERE}/../../workflows/app-ci.yml"; do
  [ -f "$ci" ] || continue
  if grep -qE 'operation=merge-gate|actions/dispatch-merge-gate' "$ci"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $(basename "$ci") has no dispatch-merge-gate job; bot pull requests would wait for the hourly belt" >&2
  fi
done

# The router forwards a fact to a worker by reading `needs.classify.outputs.<x>`; a name the
# classify job does not export resolves to '' with no error. That is how the gate received
# attempts_so_far='' (the classifier emitted merge-gate-attempts, the job never exported it),
# fromJson('') killed the incomplete job before its attempt comment, and the belt re-dispatched
# the same crash every hour. Every name the router reads must be exported by the classify job.
CLASSIFY_EXPORTS="$(tr -d '\r' <"$ROUTER_YML" |
  sed -n '/^  classify:$/,/^  [a-z-]*:$/p' |
  sed -n '/^    outputs:$/,/^    [a-z]*:$/p' |
  sed -n 's/^      \([a-zA-Z0-9_-]*\):.*/\1/p')"
CLASSIFY_OK=1
[ -n "$CLASSIFY_EXPORTS" ] || { CLASSIFY_OK=0; echo "FAIL: could not read the classify job's outputs from work-router.yml" >&2; }
while read -r name; do
  [ -n "$name" ] || continue
  if ! grep -qx "$name" <<<"$CLASSIFY_EXPORTS"; then
    CLASSIFY_OK=0
    echo "FAIL: work-router.yml reads needs.classify.outputs.${name} but the classify job does not export it" >&2
  fi
done < <(grep -oE 'needs\.classify\.outputs\.[a-zA-Z0-9_-]+' "$ROUTER_YML" | sed 's/.*\.//' | sort -u)
if [ "$CLASSIFY_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# fromJson('') is a hard failure ("Error reading JToken"), and a workflow_call input arrives as
# '' whenever the caller passes an empty expression, declared default or not. The gate must never
# hand a raw input to fromJson; `inputs.x || '0'` reads the empty case as zero.
if ! grep -qE "fromJson\(inputs\.[a-zA-Z0-9_]+\)" "$MERGE_GATE_WORKER_MD"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: merge-gate worker calls fromJson on a raw input; an empty caller value kills the job" >&2
  grep -nE "fromJson\(inputs\.[a-zA-Z0-9_]+\)" "$MERGE_GATE_WORKER_MD" >&2
fi

# The worker's own comments must keep the distinction: progress notes carry no marker,
# failed attempts carry the attempt marker, verdicts carry the marker AND the Verdict line.
# Three verdict sites: the review hold on the issue, the agent's assessment on the issue,
# and conclude's short verdict on the pull request itself.
if grep -q 'ATTEMPT_MARKER: "<!-- agent-merge-gate-attempt -->"' "$MERGE_GATE_WORKER_MD" &&
  [ "$(grep -c '\${{ env.GATE_MARKER }}' "$MERGE_GATE_WORKER_MD")" -eq 4 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: merge-gate worker must keep verdict and attempt markers distinct" >&2
fi

# add-issue-labels and remove-issue-labels split `labels` on newlines. A caller that joined two
# names with a comma removed one label called "bot-working,pr-pending": a 404 the action swallows
# on purpose, so the release never happened and Pliny-Bot #49/#54 carried implement, pr-pending
# and review together for a day. Callers use block scalars, one label per line; the actions also
# accept commas so a consumer copy of an old caller keeps working.
LABELS_OK=1
if grep -nE '^[[:space:]]+labels: [^|>].*,' "${HERE}/../../workflows"/agent-*.md >&2; then
  LABELS_OK=0
  echo "FAIL: a worker passes comma-joined labels to a label action; use a block scalar, one label per line" >&2
fi
for action in add-issue-labels remove-issue-labels; do
  if ! grep -qF 'split(/\r?\n|,/)' "${HERE}/../${action}/action.yml"; then
    LABELS_OK=0
    echo "FAIL: ${action} must accept comma-separated labels as well as one per line" >&2
  fi
done
if [ "$LABELS_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# The agent's fix reaches the branch as a bundle applied fast-forward only (apply-agent-output).
# gh-aw's push tool description tells the model to rebase, and a rebased branch cannot
# fast-forward: the push is refused and the verdict is lost (Pliny-Bot run 33952565835). The
# worker must start on the pull request branch and must never say `git rebase`. Its progress
# comment is posted on the first attempt only; retries are recorded by the attempt comment.
BRANCH_OK=1
# Path B: staged safe outputs, applied by conclude with the App token. Without `staged: true`
# gh-aw's safe_outputs job writes too, and it runs first: it pushed a flattened single-parent
# commit with GITHUB_TOKEN, which lost the agent's merge, left the pull request conflicting,
# and started no CI, because GITHUB_TOKEN writes raise no events.
if ! grep -qE '^  staged: true' "$MERGE_GATE_WORKER_MD"; then
  BRANCH_OK=0; echo "FAIL: merge-gate safe-outputs must be staged; conclude owns the write path" >&2
fi
if grep -q 'git rebase' "$MERGE_GATE_WORKER_MD"; then
  BRANCH_OK=0; echo "FAIL: merge-gate worker tells the agent to rebase; the push is fast-forward only" >&2
fi
if ! grep -q 'name: Check out the pull request branch' "$MERGE_GATE_WORKER_MD"; then
  BRANCH_OK=0; echo "FAIL: merge-gate worker must check out the pull request branch before the agent starts" >&2
fi
if ! grep -qF "conclusion == 'failure' && (inputs.attempts_so_far || '0') == '0'" "$MERGE_GATE_WORKER_MD"; then
  BRANCH_OK=0; echo "FAIL: the reserve job's progress comment must be posted on the first attempt only" >&2
fi
# A conflicting pull request has no CI run to read logs from, so the gate is handed empty
# failure artifacts. Read on its own that looks like "no evidence", and the agent asked for a
# human instead of resolving the conflict that caused it.
if ! grep -qF 'Empty failure evidence is not a reason to ask for review' "$MERGE_GATE_WORKER_MD"; then
  BRANCH_OK=0
  echo "FAIL: the gate must treat empty failure evidence on a conflicting PR as the conflict to fix" >&2
fi
if [ "$BRANCH_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# pr-pending means a pull request for this issue is open and waiting. What retires it is the
# pull request ceasing to be open, and the one route that sees that -- a bot merge, a human
# merge, or a close without one -- is stage-merge (FR-051, FR-035). It used to be removed
# inside the merge gate, so a human merge left the label on for ever, and inside apply-review,
# which stripped it while the pull request was still open: a board where issues with open pull
# requests looked like they had none. That went unnoticed while the label actions silently
# removed nothing, so the two bugs hid each other. No worker retires it now; every worker path
# leaves the pull request open. Adding it is still implement's job.
PENDING_OK=1
while read -r offending; do
  [ -n "$offending" ] || continue
  PENDING_OK=0
  echo "FAIL: ${offending} removes pr-pending while the pull request is still open; only the stage-merge route retires it" >&2
done < <(awk '
  FNR == 1 { action = "" }
  /uses: \.\/\.github\/actions\/(add|remove)-issue-labels/ { action = $0 }
  /env\.PR_PENDING_LABEL/ && action ~ /remove-issue-labels/ { print FILENAME ":" FNR }
' "${HERE}/../../workflows"/agent-*.md 2>/dev/null)
STAGE_MERGE_JOB="$(tr -d '\r' <"$ROUTER_YML" | sed -n '/^  stage-merge:$/,/^  [a-z][a-z0-9-]*:$/p')"
if [ -z "$STAGE_MERGE_JOB" ]; then
  PENDING_OK=0
  echo "FAIL: work-router.yml has no stage-merge job, so nothing retires pr-pending" >&2
elif ! grep -q 'PR_PENDING_LABEL' <<<"$STAGE_MERGE_JOB"; then
  PENDING_OK=0
  echo "FAIL: the stage-merge job never removes pr-pending; a merged pull request would leave its issue marked pending for ever" >&2
fi
if [ "$PENDING_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# A provider outage kills a run in a couple of minutes with no answer, and the same issue used
# to be handed to a human for it. The implement worker retries those and only those: a run that
# worked for half an hour and then failed produced an answer that was wrong, and repeating it
# costs the fleet the same half hour to be wrong again.
IMPLEMENT_RETRY_OK=1
for needle in 'RETRY_UNDER_MINUTES' 'ATTEMPT_MARKER' 'attempts_so_far' 'operation=implement'; do
  grep -qF "$needle" "$IMPLEMENT_WORKER_MD" || {
    IMPLEMENT_RETRY_OK=0
    echo "FAIL: implement worker lost its retry belt: no '$needle'" >&2
  }
done
# Park and retry are mutually exclusive: the retry path must never add the review label, and
# the park path must never re-dispatch.
grep -A3 'Flag for human review' "$IMPLEMENT_WORKER_MD" | grep -q "retry != 'true'" ||
  grep -B3 'Flag for human review' "$IMPLEMENT_WORKER_MD" | grep -q "retry != 'true'" || {
    IMPLEMENT_RETRY_OK=0
    echo "FAIL: the implement worker must not flag review on a run it is about to retry" >&2
  }
if [ "$IMPLEMENT_RETRY_OK" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# A failed attempt must not strip `implement`: identify-gate-subject refuses an issue
# without it, so the first crash would starve every retry at the subject check.
if grep -A6 'Park the issue' "$MERGE_GATE_WORKER_MD" | grep -q 'REVIEW_LABEL' &&
  ! grep -qF 'labels: ${{ env.WORKING_LABEL }},${{ env.IMPLEMENT_LABEL }}' "$MERGE_GATE_WORKER_MD"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the incomplete job must keep implement and only park on an exhausted budget" >&2
fi

# This repository is public. Every route a human can start from a comment, a review or a
# label must pass the authorize gate, or anyone able to comment can start a model run that
# writes code. Asserted here because removing the gate would otherwise be a silent, one-line
# change that nothing fails on.
for route in refine implement apply-review; do
  if grep -qE "route == '${route}'.*needs\.authorize\.outputs\.trusted == 'true'" "$ROUTER_YML"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: route '${route}' does not require needs.authorize.outputs.trusted" >&2
  fi
done

# Triage runs under a trusted App identity. Outside collaborators are admitted only to
# the deterministic dispatcher; the worker call itself requires a trusted actor. A
# repository that did not select triage has no triage worker and no wiring to assert;
# the exclusion check below is what asserts its absence (FR-042).
if [ -f "${HERE}/../../workflows/agent-triage.md" ]; then
  if grep -qE "dispatch-triage:.*" "$ROUTER_YML" && \
     grep -qE "route == 'triage'.*is_outside_collaborator == 'true'" "$ROUTER_YML" && \
     grep -qE "route == 'triage'.*trusted == 'true'" "$ROUTER_YML"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: route 'triage' does not dispatch outside collaborators and require a trusted worker actor" >&2
  fi
fi

for route in refine implement triage apply-review merge-gate audit bot-approve \
  audit-close cleanup-artifacts reconcile-bot-pr-runs validate release; do
  if grep -q "route == '${route}'" "$ROUTER_YML"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: work-router.yml has no job for route '${route}'" >&2
  fi
done

while read -r operation; do
  if grep -q "route == '${operation}'" "$ROUTER_YML"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: dispatch operation '${operation}' has no job in work-router.yml" >&2
  fi
done < <(sed -n '/^      operation:/,/^      issue-number:/p' "$ROUTER_YML" |
  sed -n 's/^          - //p')

# ── Route models ──────────────────────────────────────────────────────────
# The model is choosable per route (FR-077), so the worker that runs a route must name the
# model the profile chose for that route and no other. Nothing else would notice: a worker
# carrying a model no profile names compiles, runs, and bills the adopter for a model they
# did not pick. The pairs come from the profile's own projected constants, because the
# matrix runs from installed files and cannot know the profile.
#
# A worker the repository did not select is skipped rather than failed -- which capabilities
# are installed is a different question, asked elsewhere.
readonly ROUTE_MODELS="agent-implement.md=claude-sonnet-5 agent-refine.md=claude-sonnet-5 agent-triage.md=claude-sonnet-5 agent-apply-review.md=claude-sonnet-5 agent-merge-gate.md=claude-sonnet-5 agent-audit.md=claude-sonnet-5 agent-release.md=claude-sonnet-5"

for pair in $ROUTE_MODELS; do
  worker="${HERE}/../../workflows/${pair%%=*}"
  expected_model="${pair#*=}"
  [ -f "$worker" ] || continue

  actual_model="$(sed -n "s/^model: //p" "$worker" | head -1)"
  assert "${pair%%=*} runs the model the profile chose for its route" "$expected_model" "$actual_model"
done

# ── Engine credentials ────────────────────────────────────────────────────
# This repository runs one engine, and only that engine's credential variables may appear in
# a file this package installed (FR-076, FR-067). The framework derives a worker's
# `workflow_call.secrets` block from the engine alone -- verified by compiling one worker per
# engine, 17/09/2026 -- so a caller naming `OPENAI_API_KEY` against a `claude` worker is a
# secret the callee never declared, which GitHub rejects before a job is created, and a
# repository that compiled cleanly still cannot run.
#
# The scan is the files this package installs, and deliberately not the locks compiled from
# them. COPILOT_GITHUB_TOKEN means two things: under `copilot` it is the credential, and under
# every other engine the framework still declares it in the lock for its own OAuth-token
# probe. Scanning generated output would fail four engines for a name the framework chose,
# and the lock is derived from the sources this does scan.
readonly ENGINE_ID="claude"
readonly FOREIGN_CREDENTIAL_VARS="CODEX_API_KEY COPILOT_GITHUB_TOKEN GEMINI_API_KEY OPENAI_API_KEY"

engine_scan_files() {
  local candidate
  for candidate in \
    "${HERE}/../../workflows/work-router.yml" \
    "${HERE}/../../workflows/authorize-bot-work.yml" \
    "${HERE}"/../../workflows/agent-*.md \
    "${HERE}"/../../workflows/shared/*.md \
    "${HERE}/../../../opencode.ci.json"; do
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; fi
  done
}

for variable in $FOREIGN_CREDENTIAL_VARS; do
  offenders=""
  while read -r scanned; do
    if grep -qF "$variable" "$scanned"; then offenders="${offenders} ${scanned##*/}"; fi
  done < <(engine_scan_files)

  if [ -z "$offenders" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: this repository runs '${ENGINE_ID}', which never reads ${variable}, but it is named in:${offenders}" >&2
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "Route matrix: ${PASS} passed"
else
  echo "Route matrix: ${PASS} passed, ${FAIL} FAILED" >&2
fi

# Last, and in this shape, so a collector reads one line rather than parsing prose (FR-058).
echo "PASS=${PASS} FAIL=${FAIL}"

exit $((FAIL > 0))
