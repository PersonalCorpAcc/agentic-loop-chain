#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/templates/canary/canary-cycle.sh. Profile digest: fdaf7c626ab9. Update with `workflows update --force`; consumer edits may be overwritten.
#
# One canary cycle: a fixed trivial change, carried by the loop from an issue to the stage
# that closes it, with every hop asserted against what the profile says should happen
# (FR-060). Nothing here does the loop's work for it. It opens the issue, labels it, waits,
# and looks; the only writes it makes on the loop's behalf are the ones a person makes --
# the stand-in identity's approval and merge on a human-gated stage.
#
# Every wait is bounded and every failure names itself, because the point of a canary is a
# red run that says which hop broke, not a green one that says nothing. The last thing this
# writes is `reason=` and `detail=` for the outcome line: `acted` when the whole cycle held,
# `timed-out` when a hop never happened, `assertion-failed` when it happened wrongly.

# The checks below are passed to until_seen by name and called from inside it, which the
# linter cannot follow.
# shellcheck disable=SC2329

set -euo pipefail

: "${REPO:?canary-cycle: REPO is required}"
: "${GH_TOKEN:?canary-cycle: GH_TOKEN (the App token) is required}"
: "${WORKFLOW_TOKEN:?canary-cycle: WORKFLOW_TOKEN is required}"
: "${STANDIN_TOKEN:?canary-cycle: STANDIN_TOKEN is required -- the second identity that stands in for the human gate}"
: "${BOT_LOGIN:?canary-cycle: BOT_LOGIN is required}"
: "${STRATEGY:?canary-cycle: STRATEGY is required}"
: "${STAGES_CSV:?canary-cycle: STAGES_CSV is required}"
: "${BASE_BRANCH:?canary-cycle: BASE_BRANCH is required}"
: "${BRANCH_POINT:?canary-cycle: BRANCH_POINT is required}"
: "${BRANCH_PATTERN:?canary-cycle: BRANCH_PATTERN is required}"
: "${CLOSE_ISSUE_ON:?canary-cycle: CLOSE_ISSUE_ON is required}"
: "${IMPLEMENT_LABEL:?canary-cycle: IMPLEMENT_LABEL is required}"
: "${MERGED_STAGE_TEMPLATE:?canary-cycle: MERGED_STAGE_TEMPLATE is required}"
: "${MERGE_METHOD:?canary-cycle: MERGE_METHOD is required}"
: "${CANARY_FILE:?canary-cycle: CANARY_FILE is required}"
: "${GIT_IDENTITY:?canary-cycle: GIT_IDENTITY is required}"
: "${RUN_ID:?canary-cycle: RUN_ID is required}"
: "${ACTIONS_DIR:?canary-cycle: ACTIONS_DIR is required}"

AUTO_MERGE_TARGETS="${AUTO_MERGE_TARGETS:-}"
SOAK_CSV="${SOAK_CSV:-}"
MATRIX_FLOOR="${MATRIX_FLOOR:-0}"
POLL_SECONDS="${POLL_SECONDS:-30}"
# Bounded waits, in minutes. The implement run is the long one: a runner, the model and CI.
IMPLEMENT_WAIT="${IMPLEMENT_WAIT:-60}"
MERGE_WAIT="${MERGE_WAIT:-45}"
LABEL_WAIT="${LABEL_WAIT:-15}"
PROMOTE_WAIT="${PROMOTE_WAIT:-25}"
MATRIX_WAIT="${MATRIX_WAIT:-20}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

IFS=',' read -r -a stages <<<"$STAGES_CSV"
[ "${#stages[@]}" -gt 0 ] || { echo "::error::canary-cycle: STAGES_CSV names no stage."; exit 1; }
first="${stages[0]}"

note() { echo "canary: $*"; }

finish() {
  local reason="$1" detail="$2"
  {
    echo "reason=${reason}"
    echo "detail=${detail}"
    echo "issue=${issue:-}"
  } >>"$OUTPUT"
  if [ "$reason" = acted ]; then
    note "$detail"
    exit 0
  fi
  echo "::error::${detail}"
  exit 1
}

# `until <seconds> <what> <command...>`: run the command every poll until it prints something,
# and hand that back; past the deadline the cycle ends here, naming the hop that never came.
until_seen() {
  local minutes="$1" what="$2"
  shift 2
  local deadline=$(( $(date +%s) + minutes * 60 )) value
  while :; do
    value="$("$@" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      finish timed-out "No ${what} within ${minutes} minutes."
    fi
    sleep "$POLL_SECONDS"
  done
}

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

stage_label() { printf '%s' "${MERGED_STAGE_TEMPLATE//\{stage\}/$1}"; }

soak_seconds() {
  local stage="$1" entry value
  local -a entries
  IFS=',' read -r -a entries <<<"$SOAK_CSV"
  for entry in "${entries[@]}"; do
    [ "${entry%%=*}" = "$stage" ] || continue
    value="${entry#*=}"
    case "$value" in
      *s) echo "${value%s}" ;;
      *m) echo $(( ${value%m} * 60 )) ;;
      *h) echo $(( ${value%h} * 3600 )) ;;
      *d) echo $(( ${value%d} * 86400 )) ;;
      "") echo 0 ;;
      *) echo "$value" ;;
    esac
    return 0
  done
  echo 0
}

# A login as the forge reports a merger, compared without the decorations an App's login
# carries in one API and not in another.
bare_login() { local login="${1#app/}"; printf '%s' "${login%\[bot\]}"; }

IFS=',' read -r -a auto_targets <<<"$AUTO_MERGE_TARGETS"

# Everything after the field is passed on: the callers filter with --jq, and dropping it
# compared a JSON object with a branch name (the first forge run, 20/11/2026).
pr_json() { gh pr view "$1" --repo "$REPO" --json "$2" "${@:3}"; }
pr_merged() { [ "$(gh pr view "$1" --repo "$REPO" --json state --jq .state)" = MERGED ] && echo yes; }
issue_has_label() { gh issue view "$1" --repo "$REPO" --json labels --jq ".labels[].name" | grep -qxF "$2" && echo yes; }
issue_closed() { [ "$(gh issue view "$1" --repo "$REPO" --json state --jq .state)" = CLOSED ] && echo yes; }

# The stand-in is the person the gate waits for: it approves where a rule requires a review,
# and merges where this repository's policy says the loop does not. Its token is a person's,
# so the merge raises the events a person's merge raises, which is what the stage-merge
# route listens for -- a merge by the workflow token would raise none, and the issue would
# never close.
stand_in_lands() {
  local pr="$1" stage="$2" decision
  decision="$(gh pr view "$pr" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""')"
  if [ "$decision" = REVIEW_REQUIRED ] || ! contains "$stage" "${auto_targets[@]}"; then
    GH_TOKEN="$STANDIN_TOKEN" gh pr review "$pr" --repo "$REPO" --approve \
      --body "Canary stand-in for the human gate on \`${stage}\` (run ${RUN_ID})." >/dev/null ||
      finish assertion-failed "The stand-in identity could not approve #${pr} into ${stage}; check its token's repository access and pull-request permission."
    note "the stand-in approved #${pr} into ${stage}"
  fi
  if ! contains "$stage" "${auto_targets[@]}"; then
    GH_TOKEN="$STANDIN_TOKEN" gh pr merge "$pr" --repo "$REPO" "--${MERGE_METHOD}" --auto >/dev/null ||
      finish assertion-failed "The stand-in identity could not merge #${pr} into ${stage}; its token needs contents write as well as pull requests."
    note "the stand-in armed the merge of #${pr} into ${stage}, which this repository's policy leaves to a person"
  fi
}

promoting=false
case "$STRATEGY" in
  branch-chain | env-promotion) promoting=true ;;
esac

# ── 1. Under a chain, a base-only edit to the same file first ────────────────────────────
# The failure this catches is the one T200 found: a pull request whose head carries a commit
# that is on the base and not on the branch point, which is what a base rewrite looks like.
# An edit that lands on the first stage before the issue exists makes that commit real.
if [ "$promoting" = true ]; then
  base_branch="canary/base-${RUN_ID}"
  # Authenticated, because the checkout keeps no credentials and a private repository
  # refuses an anonymous fetch -- the defect class that found `contents: read` missing.
  git fetch -q --no-tags "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "${first}:refs/remotes/origin/${first}"
  git switch -q -C "$base_branch" "origin/${first}"
  mkdir -p "$(dirname "$CANARY_FILE")"
  if [ -f "$CANARY_FILE" ]; then
    sed -i "1s/.*/Last base-only edit: run ${RUN_ID}/" "$CANARY_FILE"
  else
    printf 'Last base-only edit: run %s\n\nThe agentic loop appends one line here each day (FR-060).\n' "$RUN_ID" >"$CANARY_FILE"
  fi
  git add -- "$CANARY_FILE"
  git -c user.name="$GIT_IDENTITY" -c user.email="${GIT_IDENTITY}@users.noreply.github.com" \
    commit -q -m "Canary: base-only edit on ${first} (run ${RUN_ID})"
  git push -q "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "HEAD:refs/heads/${base_branch}"
  base_pr="$(gh pr create --repo "$REPO" --base "$first" --head "$base_branch" \
    --title "[canary] Base-only edit on ${first} (run ${RUN_ID})" \
    --body "A base-only edit to \`${CANARY_FILE}\`, landed before today's canary issue exists so that its pull request has a real base commit to not carry (FR-060, FR-061)." |
    sed -n 's#.*/pull/\([0-9]*\)$#\1#p')"
  [ -n "$base_pr" ] || finish assertion-failed "The base-only edit's pull request into ${first} could not be opened."
  gh pr merge "$base_pr" --repo "$REPO" "--${MERGE_METHOD}" --auto >/dev/null ||
    finish assertion-failed "Auto-merge could not be armed on the base-only edit #${base_pr}; is 'Allow auto-merge' on?"
  until_seen "$MERGE_WAIT" "merge of the base-only edit #${base_pr} into ${first}" pr_merged "$base_pr" >/dev/null
  note "the base-only edit #${base_pr} landed on ${first}"
fi

# The tips the created pull request is checked against, as the implement route's reserve
# job records them: the branch point is where the work must be cut from.
base_tip="$(gh api "repos/${REPO}/branches/${BASE_BRANCH}" --jq .commit.sha)"
branch_point_tip="$(gh api "repos/${REPO}/branches/${BRANCH_POINT}" --jq .commit.sha)"

# ── 2. The issue ─────────────────────────────────────────────────────────────────────────
# Trivial, and fixed: the same change every day, so a failure is the loop's and not the
# task's. Labelled by the App, which is the event the router starts the worker on.
issue_url="$(gh issue create --repo "$REPO" \
  --title "[canary] Daily cycle, run ${RUN_ID}" \
  --body "<!-- complexity: trivial -->
The daily canary change (FR-060). The canary workflow opened this issue and watches it until it closes; nothing here needs a person.

- [ ] Append the line \`canary ${RUN_ID}\` to the end of \`${CANARY_FILE}\`, creating the file if it does not exist. Change nothing else.")"
issue="${issue_url##*/}"
gh issue edit "$issue" --repo "$REPO" --add-label "$IMPLEMENT_LABEL" >/dev/null
note "opened #${issue} and labelled it ${IMPLEMENT_LABEL}"

# ── 3. The implementing pull request ─────────────────────────────────────────────────────
# Found through the link the App records on the issue, which is the only link this loop
# trusts (FR-064), and then checked by the same action the implement route's conclude runs.
linked_pr() {
  local out
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" ISSUE_NUMBER="$issue" bash "${ACTIONS_DIR}/resolve-change-linkage/resolve-change-linkage.sh" >/dev/null 2>&1 || true
  sed -n 's/^pr=//p' "$out"
  rm -f "$out"
}
pr="$(until_seen "$IMPLEMENT_WAIT" "pull request linked to #${issue} by the App" linked_pr)"
note "#${issue} has pull request #${pr}"

base="$(pr_json "$pr" baseRefName --jq .baseRefName)"
[ "$base" = "$first" ] || finish assertion-failed "Pull request #${pr} targets ${base}; the profile's first stage is ${first}."
PR_NUMBER="$pr" BASE_TIP="$base_tip" BRANCH_POINT_TIP="$branch_point_tip" \
  bash "${ACTIONS_DIR}/verify-created-pull-request/verify-created-pull-request.sh" ||
  finish assertion-failed "Pull request #${pr} is not the pull request the loop asked for; its checks are in the step log above."
note "#${pr} has the template's branch name, no closing keyword, and no commit from the base that is not on the branch point"

# ── 4. Each stage in turn ────────────────────────────────────────────────────────────────
for index in "${!stages[@]}"; do
  stage="${stages[index]}"
  if [ "$index" -gt 0 ]; then
    wait_for="$(soak_seconds "$stage")"
    note "soaking ${wait_for}s before promoting into ${stage}"
    sleep "$(( wait_for + 30 ))"
    GH_TOKEN="$WORKFLOW_TOKEN" gh workflow run work-router.yml --repo "$REPO" --ref "${DEFAULT_BRANCH:-main}" \
      -f operation=promote >/dev/null
    promotion() {
      gh pr list --repo "$REPO" --state all --base "$stage" --limit 30 --json number,body \
        --jq "[.[] | select((.body // \"\") | contains(\"<!-- implement-issue: ${issue} -->\"))][0].number // empty"
    }
    pr="$(until_seen "$PROMOTE_WAIT" "promotion of #${issue} into ${stage}" promotion)"
    pr_json "$pr" body --jq .body | grep -qF "<!-- promotion-pr: ${stage}: " ||
      finish assertion-failed "Promotion pull request #${pr} into ${stage} does not carry the promotion marker."
    note "#${issue} is promoted into ${stage} as #${pr}"
  fi

  stand_in_lands "$pr" "$stage"
  until_seen "$MERGE_WAIT" "merge of #${pr} into ${stage}" pr_merged "$pr" >/dev/null
  if contains "$stage" "${auto_targets[@]}"; then
    merger="$(pr_json "$pr" mergedBy --jq '.mergedBy.login // ""')"
    [ "$(bare_login "$merger")" = "$(bare_login "$BOT_LOGIN")" ] ||
      finish assertion-failed "#${pr} into ${stage} was merged by ${merger:-nobody}, where the profile lets the loop merge that stage itself."
  fi

  label="$(stage_label "$stage")"
  until_seen "$LABEL_WAIT" "label ${label} on #${issue} after #${pr} merged" issue_has_label "$issue" "$label" >/dev/null
  if [ "$stage" = "$CLOSE_ISSUE_ON" ]; then
    until_seen "$LABEL_WAIT" "close of #${issue} at ${stage}, where the profile closes it" issue_closed "$issue" >/dev/null
  elif [ "$(issue_closed "$issue")" = yes ]; then
    finish assertion-failed "#${issue} closed at ${stage}; the profile closes it at ${CLOSE_ISSUE_ON}."
  fi
  note "${stage}: #${pr} merged, #${issue} labelled ${label}"
done

[ "$(issue_closed "$issue")" = yes ] ||
  finish assertion-failed "#${issue} reached every stage and is still open; the profile closes it at ${CLOSE_ISSUE_ON}."

# ── 5. The route matrix, from the default branch's own copy ──────────────────────────────
dispatched_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GH_TOKEN="$WORKFLOW_TOKEN" gh workflow run work-router.yml --repo "$REPO" --ref "${DEFAULT_BRANCH:-main}" \
  -f operation=validate >/dev/null
validate_run() {
  GH_TOKEN="$WORKFLOW_TOKEN" gh run list --repo "$REPO" --workflow work-router.yml --event workflow_dispatch \
    --limit 10 --json databaseId,createdAt,status \
    --jq "[.[] | select(.createdAt >= \"${dispatched_at}\" and .status == \"completed\")] | last | .databaseId // empty"
}
run="$(until_seen "$MATRIX_WAIT" "completed validate run after ${dispatched_at}" validate_run)"
counts="$(GH_TOKEN="$WORKFLOW_TOKEN" gh run view "$run" --repo "$REPO" --log 2>/dev/null |
  grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' | tail -n 1 || true)"
[ -n "$counts" ] || finish assertion-failed "The validate run ${run} printed no route-matrix count."
passed="${counts#PASS=}"
passed="${passed%% *}"
failed="${counts##*FAIL=}"
[ "$failed" -eq 0 ] || finish assertion-failed "The route matrix failed ${failed} row(s) in run ${run}."
[ "$passed" -ge "$MATRIX_FLOOR" ] ||
  finish assertion-failed "The route matrix passed ${passed} row(s), below the ${MATRIX_FLOOR} this repository has passed before: rows went missing."

route="${stages[0]}"
for stage in "${stages[@]:1}"; do route="${route} → ${stage}"; done
finish acted "#${issue} went from an issue to ${CLOSE_ISSUE_ON} through ${route}, every hop as the profile says, and the route matrix passed ${passed} of ${passed}."
