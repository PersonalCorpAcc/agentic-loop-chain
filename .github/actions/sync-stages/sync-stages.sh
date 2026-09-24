#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/sync-stages/sync-stages.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Carry a change that arrived on a later stage back down the chain (FR-079).
#
# The promotion route walks the chain upward, and everything that goes up arrives that way.
# Nothing went the other direction: a hotfix committed to `main`, an administrative or
# configuration push, a revert applied where the damage was, all of them land on a later
# stage and never reach the earlier ones. `promote-change.sh` already reads the hotfix label
# and says "it takes its own path"; this file is that path.
#
# The symptom is indirect and expensive, which is why it needs a route rather than a note in
# a runbook. Under a rebase promotion the stages diverge permanently by design -- the same
# change carries a different sha on each stage -- so ancestry cannot answer "is `dev` behind
# `main`". When the earlier stage falls behind, the next pull request into it carries the
# whole delta; that trips the protected-files rule; that skips the model entirely; and the
# result is a green run that proved nothing. It cost three inconclusive gating tests on
# 17/09/2026 before the cause was found three steps upstream.
#
# Two rules keep it safe, and neither is optional:
#
#   * Downward only. The earlier stage being **ahead** with work that has not been promoted
#     yet is the normal state of a chain, and this route must never disturb it. Nothing here
#     writes, rewrites or reads back from the later stage at all.
#   * By content, never by ancestry. Both directions have to be able to be true at once --
#     `dev` ahead by un-promoted work and behind by a hotfix -- which is exactly what a
#     patch-id comparison allows and an ancestry check cannot express.
#
# And never a direct push: what is missing arrives as a pull request, so it gets CI, the
# merge gate and the same policy as anything else, and `guard-branch-write` stays the only
# thing that writes a stage.

set -euo pipefail

: "${REPO:?sync-stages: REPO is required}"
: "${STAGE_BRANCHES:?sync-stages: STAGE_BRANCHES is required}"

opened=0
reason="stages-aligned"

note() { echo "$*"; }

# One run looks at every pair in the chain, so it collects several answers and reports one
# (FR-058). The ranking is how much each answer wants a person, because letting the last one
# win hides the ones that do -- and a conflict wants one more than an opened pull request
# does, so it outranks that too. A run that repairs two hops and hands a third over is
# ordinary now that every detached hop is repaired in the same pass, and reporting it as
# `acted` would be the last-one-wins mistake in a different costume (FR-086).
skipped_because() {
  local candidate="$1" entry
  if [ "$candidate" != "conflict-handed-off" ] && [ "$opened" -ne 0 ]; then
    return 0
  fi
  for entry in conflict-handed-off already-present stages-aligned; do
    case "$entry" in
      "$candidate") reason="$candidate"; return 0 ;;
      "$reason") return 0 ;;
    esac
  done
}

finish() {
  # `acted` is the answer when something was opened and nothing was handed over: the
  # hand-off is set by skipped_because and outranks it.
  [ "$opened" -eq 0 ] || [ "$reason" = "conflict-handed-off" ] || reason="acted"
  {
    echo "opened=${opened}"
    echo "reason=${reason}"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  note "Synchronisation pull requests opened: ${opened}."
  exit 0
}

IFS=',' read -r -a stages <<<"$STAGE_BRANCHES"
if [ "${#stages[@]}" -lt 2 ]; then
  note "This repository merges into one branch, so no stage can fall behind another."
  finish
fi

# There used to be an early exit here for `env-promotion`, on the grounds that its later
# stages are snapshots of the branch before them rather than histories of their own, so a
# stage could not hold content another one is missing.
#
# That is true of everything the loop does and says nothing about people, which is the only
# drift this route exists for: FR-079 is about a person pushing to a later stage. On
# 22/09/2026 three configuration commits went straight to `main` on the canary -- the gate
# fix, the branch point and the merge method -- and `test` and `dev` were left four commits
# and a materially different profile behind. This route ran in 21 milliseconds and reported
# `stages-aligned`, which is not "I did not look": it is a positive assertion that every
# stage carries the content of the ones after it. The belt was switched off precisely under
# the strategy where the drift then happened.
#
# The comparison below is sound under this strategy now, and it is worth saying why it was
# not obviously so before. It rests on ancestry to narrow the candidates, and under
# `env-promotion` that only holds if a promotion leaves its snapshot an ancestor of the stage
# above -- which is exactly what the conventional merge method now guarantees. A profile that
# squashes or rebases its promotions gets a wider candidate list here, and the patch-id filter
# below removes the ones already present by content, so the answer stays correct and the run
# costs a little more.

# Every commit reachable from a ref, as patch-ids. The same code and the same reason as
# promote-change.sh: a patch-id is the content, so a change that travelled up the chain
# under a rebase answers the same on both stages even though its sha does not. A comparison
# by sha would report every promoted change as missing, and this route would carry the whole
# chain back down on its first run.
patch_ids_of() {
  local ref="$1" limit="${2:-${HISTORY_LIMIT:-200}}" sha
  git log --format=%H "$ref" 2>/dev/null | head -n "$limit" | while read -r sha; do
    git show "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
  done
}

# From the top down: `main` to `test`, then `test` to `dev`. In that order because a hotfix
# on `main` belongs on every stage below it, and doing the top pair first means the run that
# carries it into `test` leaves it visible to the next run's `test` → `dev` comparison.
for (( index=${#stages[@]} - 1; index > 0; index-- )); do
  later="${stages[index]}"
  earlier="${stages[index - 1]}"

  note "── ${later} → ${earlier} ─────────────────────────────────────────"

  git fetch --no-tags origin "${later}:refs/remotes/origin/${later}" "${earlier}:refs/remotes/origin/${earlier}" >/dev/null 2>&1 || true

  if ! git rev-parse --verify --quiet "refs/remotes/origin/${later}" >/dev/null ||
    ! git rev-parse --verify --quiet "refs/remotes/origin/${earlier}" >/dev/null; then
    note "::warning::One of ${later} and ${earlier} does not exist on the remote; nothing to compare."
    continue
  fi

  # One open synchronisation per target, for the same reason promotion allows one: two pull
  # requests into the same stage are built on the same tip, and whichever merges second
  # carries content the first never saw. Matched on a marker only this route writes.
  open_sync="$(gh pr list --repo "$REPO" --state open --base "$earlier" --json number,body \
    --jq "[.[] | select((.body // \"\") | contains(\"<!-- sync-pr: ${earlier}: \"))][0].number // empty")"
  if [ -n "$open_sync" ]; then
    note "Pull request #${open_sync} is already carrying content into ${earlier}; nothing else goes there until it lands."
    skipped_because "already-present"
    continue
  fi

  # Reachable from the later stage and not from the earlier one, oldest first, merges
  # excluded: a merge commit joins two histories the earlier stage does not have, and
  # cherry-picking one is not a thing that can succeed.
  mapfile -t candidates < <(
    git log --no-merges --reverse --format=%H \
      "refs/remotes/origin/${earlier}..refs/remotes/origin/${later}" 2>/dev/null |
      head -n "${HISTORY_LIMIT:-200}"
  )
  if [ "${#candidates[@]}" -eq 0 ]; then
    note "${earlier} already has every commit ${later} does."
    skipped_because "stages-aligned"
    continue
  fi

  # The sha filter above is not the answer, only a cheap way to get the candidates: under a
  # rebase promotion every change that went up the chain is in that list. This is the filter
  # that decides.
  mapfile -t present < <(patch_ids_of "refs/remotes/origin/${earlier}")

  to_pick=()
  for sha in "${candidates[@]}"; do
    pid="$(git show "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
    already=false
    for known in "${present[@]}"; do
      if [ -n "$pid" ] && [ "$pid" = "$known" ]; then
        already=true
        break
      fi
    done
    [ "$already" = true ] || to_pick+=("$sha")
  done

  # Content is half the question, and on its own it is the wrong half. Under a rebase
  # promotion the earlier stage always carries the content already -- that is what
  # promotion did -- so a content-only test reports every hop aligned and the histories
  # stay apart for ever. The merge below is guarded by the question that matters, and this
  # exit used to return before reaching it (FR-086).
  if [ "${#to_pick[@]}" -eq 0 ] &&
     git merge-base --is-ancestor "refs/remotes/origin/${later}" "refs/remotes/origin/${earlier}"; then
    note "${earlier} already carries the content of every commit on ${later}, and contains them."
    skipped_because "stages-aligned"
    continue
  fi

  if [ "${#to_pick[@]}" -eq 0 ]; then
    note "${earlier} carries the content of every commit on ${later} but does not contain them: this is the merge-base repair, and the merge will change no file."
  else
    note "${earlier} is missing ${#to_pick[@]} commit(s) that ${later} has."
  fi

  sync_branch="sync/${earlier}-${GITHUB_RUN_ID:-0}"

  # The deny-list applies to what this job writes exactly as it does to an agent's push: a
  # stage, the branch point or a release branch is never a synchronisation head (FR-063).
  if ! BRANCH="$sync_branch" \
    DENIED_BRANCHES="${STAGE_BRANCHES}" \
    RELEASE_PATTERN="${RELEASE_PATTERN:-}" \
    BRANCH_PATTERN="${SYNC_BRANCH_PATTERN:-^sync/}" \
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-}" \
    bash "${GITHUB_ACTION_PATH}/../guard-branch-write/guard-branch-write.sh"; then
    note "Refusing to write ${sync_branch}; nothing done for ${later} → ${earlier}."
    continue
  fi

  git switch --detach "refs/remotes/origin/${earlier}" >/dev/null 2>&1
  git switch -c "$sync_branch" >/dev/null 2>&1

  # A merge, not a sequence of cherry-picks (FR-082).
  #
  # Cherry-picking gave the earlier stage the *content* and not the *history*, and the
  # difference is not academic: a pull request's file list is computed against the merge base,
  # so until `dev` actually contains `main`'s commits every pull request into `dev` diffs
  # against a point before the drift and carries files it never touched. That trips the
  # protected-files rule, hands the change to a person, and makes any test on it prove
  # nothing -- which is what happened on the canary on 18/09/2026: two sync pull requests had
  # merged, `doctor` reported the stages aligned, and the next agent's pull request still
  # showed eighty files. One merge commit fixed it, and the next one showed two.
  #
  # A back-merge is also the conventional shape: it is how a hotfix on a release branch
  # reaches development in every branching model that has one. And it makes the merge method
  # this pull request needs enforceable rather than hoped for -- a head containing a merge
  # commit is one GitHub will not offer "rebase and merge" for.
  merge_message="sync: carry ${later} into ${earlier}"
  if ! git merge --no-ff -m "$merge_message" "refs/remotes/origin/${later}" >/dev/null 2>&1; then
    conflict_files="$(git diff --name-only --diff-filter=U 2>/dev/null | head -n 20 | tr '\n' ' ')"
    git merge --abort >/dev/null 2>&1 || true
    # Nothing has been pushed: the branch exists in this checkout only, and both stages are
    # exactly as they were. No agent is asked to resolve it, for the same reason promotion
    # does not (T131, FR-034).
    #
    # The hand-off is an annotation and the outcome line rather than an issue comment,
    # because a back-propagation belongs to no issue: what arrived outside the loop had no
    # issue in the loop, which is the whole reason it is here.
    note "::error::${later} → ${earlier}: the merge does not apply cleanly. Conflicting files: ${conflict_files:-not recorded}. Nothing was pushed; both branches are as they were. Carry it across by hand: branch from ${earlier}, merge ${later}, resolve, and open a pull request into ${earlier}."
    skipped_because "conflict-handed-off"
    git switch --detach "refs/remotes/origin/${earlier}" >/dev/null 2>&1 || true
    continue
  fi

  # `--no-ff` always writes a commit, so "nothing to do" is a tree that did not move rather
  # than a HEAD that did not move. A merge that changes no file is still worth opening where
  # the histories have diverged -- that is precisely the merge-base repair -- so this only
  # skips when the earlier stage already contained the later one.
  if git merge-base --is-ancestor "refs/remotes/origin/${later}" "refs/remotes/origin/${earlier}"; then
    note "${earlier} already contains ${later}; nothing to carry."
    skipped_because "stages-aligned"
    git switch --detach "refs/remotes/origin/${earlier}" >/dev/null 2>&1 || true
    continue
  fi

  git push --force-with-lease origin "HEAD:refs/heads/${sync_branch}"

  body="Carries \`${later}\` back into \`${earlier}\`.

A change reached \`${later}\` without coming up the chain -- a hotfix, an administrative push, or a revert -- so \`${earlier}\` does not have it. Until it does, every pull request into \`${earlier}\` carries this delta as well as its own change, which trips the protected-files rule and hands work to a person that nobody needed to look at.

Commits missing by content: ${#to_pick[@]}. Zero is a reason to merge, not a reason not to: it means the content travelled and the history did not, which is the state that makes every pull request into \`${earlier}\` diff against the wrong point. This is a **merge**, not a replay: the content is only half of it, and the other half is that \`${earlier}\` should contain \`${later}\`'s commits, so that a pull request into \`${earlier}\` diffs against the right point. Where this repository merges into \`${earlier}\` unattended, **auto-merge is armed on this with a merge commit** and it lands on its own once its checks pass; where it does not, or where arming was refused -- usually because **Allow auto-merge** is off -- merge it by hand, **with a merge commit**. Squashing it would carry the content and leave the histories apart, which is the state this pull request exists to end; GitHub will not offer rebase, because the head is a merge.

Nothing on \`${later}\` was touched, and nothing on \`${earlier}\` is removed by this.

<!-- sync-pr: ${earlier}: ${later} -->"
  new_pr="$(gh pr create --repo "$REPO" --base "$earlier" --head "$sync_branch" \
    --title "${TITLE_PREFIX:-[bot] }sync ${later} to ${earlier}" --body "$body" |
    grep -oE '[0-9]+$' || true)"

  note "Opened pull request #${new_pr:-?} carrying ${later} into ${earlier}."

  # Nobody waits for this. It repairs drift the loop itself caused by promoting, it adds no
  # work of its own, and its checks judge it like any other pull request -- so it is armed
  # rather than announced. A merge commit whatever `branching.mergeMethod` says: the head is
  # a merge, the forge will not offer rebase for it, and a squash would carry the content and
  # leave the histories apart, which is the state this pull request exists to end (FR-086).
  # Whether the loop may merge into this stage without a person is the adopter's answer,
  # not this route's: `autoMerge.mode` and `autoMerge.targets` say it for every other merge
  # the loop makes, and a carry-down that ignored them would be the package deciding an
  # adopter's policy (FR-086, FR-080).
  may_arm=false
  if [ "${AUTO_MERGE_MODE:-off}" != "off" ]; then
    case ",${AUTO_MERGE_TARGETS:-}," in
      *",${earlier},"*) may_arm=true ;;
    esac
  fi

  if [ -n "${new_pr:-}" ] && [ "$may_arm" != true ]; then
    note "#${new_pr} waits for a person: this repository does not merge into ${earlier} unattended (autoMerge.mode=${AUTO_MERGE_MODE:-off}, targets=${AUTO_MERGE_TARGETS:-none}). Until it lands, a branch cut from ${later} cannot be merged into ${earlier}."
  elif [ -n "${new_pr:-}" ]; then
    if armed="$(gh pr merge "$new_pr" --repo "$REPO" --merge --auto 2>&1)"; then
      note "Auto-merge armed on #${new_pr}: it lands as a merge commit when its checks pass."
    else
      # Named rather than swallowed: the usual cause is a repository setting, and a pull
      # request nobody is waiting for is exactly the kind that sits for a week.
      note "::warning::Auto-merge could not be armed on #${new_pr} (${armed}); it waits for a person. If that says Allow auto-merge is off, it is a repository setting rather than a fault here."
    fi
  fi
  opened=$((opened + 1))
  [ "$reason" = "conflict-handed-off" ] || reason="acted"
  git switch --detach "refs/remotes/origin/${earlier}" >/dev/null 2>&1 || true
done

finish
