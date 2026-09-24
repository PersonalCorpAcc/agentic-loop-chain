#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/promote-change/promote-change.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Move the changes that are ready one stage along the chain (FR-031).
#
# Deterministic from end to end, and deliberately not an agent: which commits belong to a
# change, whether its soak has elapsed and where it goes next are arithmetic over the forge
# and the clock. An agent here would also be unable to do the job -- its push applies a git
# bundle fast-forward only, and a promotion recreates a branch on the next stage and
# cherry-picks onto it, which is not a fast-forward of anything (research R2).
#
# One target at a time, oldest change first, and nothing is forced: a promotion that cannot
# be made cleanly is left for a person, with the reason on the issue.

set -euo pipefail

: "${REPO:?promote-change: REPO is required}"
: "${STAGE_BRANCHES:?promote-change: STAGE_BRANCHES is required}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../resolve-pr-issue/resolve-pr-issue.sh
. "${GITHUB_ACTION_PATH}/../resolve-pr-issue/resolve-pr-issue.sh"

promoted=0
reason="no-eligible-change"

note() { echo "$*"; }

# The one place this route says what it did. Two paths reach it -- the cherry-picking one
# below and the snapshot one of env-promotion -- and a second copy of these three lines is
# how the two strategies would come to report their outcomes differently.
report_and_exit() {
  {
    echo "promoted=${promoted}"
    echo "reason=${reason}"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  note "Promotions opened: ${promoted}."
  exit 0
}

# One run looks at every pair in the chain and every merged change on each, so it collects
# several answers and reports one (FR-058).
#
# A promotion that happened outweighs anything skipped afterwards: the outcome line says
# what the run did, and it did promote. Among the skips the ranking is how much each wants a
# person, because letting the last one win hides the ones that do: a run that handed a
# conflict over and then passed over a change already present would report the change
# already present, and nobody would go and look at the conflict.
skipped_because() {
  local candidate="$1" entry
  [ "$promoted" -eq 0 ] || return 0
  for entry in conflict-handed-off rollback hold hotfix soak-pending already-present no-eligible-change; do
    case "$entry" in
      "$candidate") reason="$candidate"; return 0 ;;
      "$reason") return 0 ;;
    esac
  done
}

# `dev,test,main` as an array, in chain order: promotion is always from one entry to the
# next, so the pairs are what this file actually works in.
IFS=',' read -r -a stages <<<"$STAGE_BRANCHES"
# release-branch has no chain and promotes nothing between stages. What this route does for
# it is cut the next release branch from the trunk on the profile's cadence (FR-055).
#
# The version is the period the cadence names, because that is the only identifier available
# to a deterministic job: nothing here may read a package manifest, which would be a stack
# assumption, and nothing may ask an agent. A repository that wants semantic versions cuts
# its branches by hand and this route leaves them alone -- it only ever creates the branch
# for the current period, and only when that branch does not exist.
cut_release_branch() {
  local version name trunk="${stages[0]}"

  if [ -z "${RELEASE_TEMPLATE:-}" ]; then
    note "This repository states no release branch template, so there is nothing to cut."
    return 0
  fi

  case "${CADENCE:-}" in
    daily) version="$(date -u +%Y.%m.%d)" ;;
    weekly) version="$(date -u +%Y-W%V)" ;;
    monthly) version="$(date -u +%Y.%m)" ;;
    quarterly) version="$(date -u +%Y).Q$(( ($(date -u +%-m) + 2) / 3 ))" ;;
    *)
      note "::warning::'${CADENCE:-}' is not a cadence this route can turn into a period, so it cannot name a release branch. Nothing cut."
      return 0
      ;;
  esac

  name="${RELEASE_TEMPLATE//"{version}"/"$version"}"

  if git ls-remote --exit-code --heads origin "$name" >/dev/null 2>&1; then
    note "${name} already exists; this period's release branch has been cut."
    skipped_because "already-present"
    return 0
  fi

  git fetch --no-tags origin "${trunk}:refs/remotes/origin/${trunk}" >/dev/null 2>&1 || true
  if ! git rev-parse --verify --quiet "refs/remotes/origin/${trunk}" >/dev/null; then
    note "::warning::The trunk '${trunk}' is not readable in this checkout; nothing cut."
    return 0
  fi

  # No lease and no force: the branch is new, and one that already existed was answered
  # above. A release branch this route overwrote would be a released history rewritten.
  git push origin "refs/remotes/origin/${trunk}:refs/heads/${name}"
  note "Cut ${name} from ${trunk}."
  promoted=$((promoted + 1))
  reason="promoted"
}

if [ "${BRANCH_STRATEGY:-}" = "release-branch" ]; then
  cut_release_branch
  report_and_exit
fi

if [ "${#stages[@]}" -lt 2 ]; then
  note "This repository has one stage, so there is nowhere to promote to."
  report_and_exit
fi

# The soak a stage demands, from `stage=duration` pairs. An absent entry is no soak.
soak_for() {
  local stage="$1" pair
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    case "$pair" in
      "${stage}="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done < <(printf '%s\n' "${SOAK:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '0'
}

# `30m`, `48h`, `5d` in seconds. The schema has already refused anything else.
duration_seconds() {
  local value="${1:-0}" number unit
  number="${value%[a-z]}"
  unit="${value##*[0-9]}"
  case "$unit" in
    m) echo $((number * 60)) ;;
    h) echo $((number * 3600)) ;;
    d) echo $((number * 86400)) ;;
    *) echo 0 ;;
  esac
}

# Every commit reachable from a ref, as patch-ids. A patch-id is the content, so the same
# change cherry-picked, rebased or squashed answers the same both sides of a promotion --
# which is what "already present" has to mean. A message comparison would call two
# different fixes with the same subject the same commit, and a re-run would then skip work
# it had never done (FR-032).
patch_ids_of() {
  local ref="$1" limit="${2:-500}" sha
  git log --format=%H "$ref" 2>/dev/null | head -n "$limit" | while read -r sha; do
    git show "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
  done
}

# The commits this change is made of, which is a different question per merge method
# (FR-032). None of them is "the commits on the branch": promotion force-pushes branches,
# so the branch is this route's own scratch space rather than a record of anything.
identify_commits() {
  local pr="$1"
  local merge_commit squashed

  case "${MERGE_METHOD:-rebase}" in
    rebase)
      # The forge replayed each commit onto the base, so the pull request's own list is the
      # change. Read through refs/pull/N/head, because the branch it came from may already
      # have been force-pushed by a later promotion, and fetched explicitly since a checkout
      # brings down heads only.
      git fetch --no-tags --quiet origin "refs/pull/${pr}/head:refs/remotes/pull/${pr}" 2>/dev/null || true
      gh api "repos/${REPO}/pulls/${pr}/commits" --paginate --jq '.[].sha'
      ;;
    squash)
      # One commit, written by the forge, containing the whole change. Reconstructing the
      # pull request's own commits here would put work on the next stage that never existed
      # on this one.
      #
      # Fetched before it is named, like the other two arms: a checkout brings down what the
      # run needs and nothing else, so handing an unfetched sha to `git show` exits 128 and
      # takes the whole route with it. Found the first time a repository promoted under
      # squash rather than rebase, which is also why the unit test did not catch it -- its
      # harness builds a full local repository (FR-032).
      squashed="$(gh api "repos/${REPO}/pulls/${pr}" --jq '.merge_commit_sha // empty')"
      [ -n "$squashed" ] || return 0
      git fetch --no-tags --quiet origin "$squashed" 2>/dev/null || true
      printf '%s\n' "$squashed"
      ;;
    merge)
      # A merge commit has two parents: the stage, and the change. Everything reachable from
      # the second parent and not from the first is what came in with it, oldest first, and
      # the merge commit itself is not carried -- it joins two histories this stage does not
      # have.
      merge_commit="$(gh api "repos/${REPO}/pulls/${pr}" --jq '.merge_commit_sha // empty')"
      [ -n "$merge_commit" ] || return 0
      git fetch --no-tags --quiet origin "$merge_commit" 2>/dev/null || true
      git rev-list --reverse --no-merges "${merge_commit}^1..${merge_commit}^2" 2>/dev/null || true
      ;;
  esac
}

# Was this change taken back out of the stage it is being promoted from?
#
# The label is the polite way to say so, and somebody reverting a commit on `dev` at five
# o'clock is not thinking about labels. Half an hour later the promotion route would carry
# the same change onto `test`, because a label was the only thing it was looking at. git
# writes the answer into the revert itself -- `This reverts commit <sha>` -- so it is there
# whether or not a person thought to say so.
#
# Matched by patch-id rather than by sha, because the sha on the stage is not the sha in the
# pull request under squash, and need not be under rebase either: what a revert undoes is a
# content, and content is what identifies a change throughout this file (FR-032). The
# reverted commit has to be one this clone can read, which it is when it is an ancestor of
# the stage the revert is on; when it is not, there is nothing to compare and the label
# remains the only signal.
was_rolled_back() {
  local stage="$1"
  shift
  local change_ids=("$@")
  local trailer reverted_sha reverted_id known

  while IFS= read -r trailer; do
    reverted_sha="${trailer##* }"
    [ -n "$reverted_sha" ] || continue
    git cat-file -e "${reverted_sha}^{commit}" 2>/dev/null || continue

    reverted_id="$(git show "$reverted_sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
    [ -n "$reverted_id" ] || continue

    for known in "${change_ids[@]}"; do
      if [ "$known" = "$reverted_id" ]; then
        printf '%s' "$reverted_sha"
        return 0
      fi
    done
  done < <(git log -n 200 --format=%B "refs/remotes/origin/${stage}" 2>/dev/null |
    grep -oE 'This reverts commit [0-9a-f]{7,40}' || true)

  return 1
}

has_label() {
  local issue="$1" name="$2"
  [ -n "$name" ] || return 1
  gh issue view "$issue" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>/dev/null |
    jq -e --arg name "$name" 'index($name)' >/dev/null 2>&1
}

# Every issue a set of commits belongs to, one per line, each once and in the order the
# commits were made. The forge's commit-to-pull-requests lookup is what makes this work for
# all three merge methods at once: a squashed change, a rebased one and a merge commit all
# answer with the pull request they came from, which is the one question that survives the
# forge rewriting history (FR-031).
issues_behind() {
  local sha pr seen_prs="" seen_issues="" issue
  for sha in "$@"; do
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      case " ${seen_prs} " in *" ${pr} "*) continue ;; esac
      seen_prs="${seen_prs} ${pr}"
      issue="$(pr_issue "$pr")"
      [ -n "$issue" ] || continue
      case " ${seen_issues} " in *" ${issue} "*) continue ;; esac
      seen_issues="${seen_issues} ${issue}"
      printf '%s\n' "$issue"
    done < <(gh api "repos/${REPO}/commits/${sha}/pulls" --jq '.[].number' 2>/dev/null || true)
  done
}

# env-promotion, which reconstructs nothing (FR-031).
#
# The head is a snapshot: a new branch created at one commit of the stage below, with no
# cherry-pick and no force-push. It is a snapshot rather than the stage branch itself because
# the stage branch keeps moving -- a pull request opened from `dev` carries every merge that
# lands on `dev` afterwards, with no soak measured and no hold consulted, and the promotion
# a person reviewed on Tuesday is not the one that merges on Wednesday.
#
# Eligibility is per stage rather than per change, which is the whole difference from the
# cherry-picking path below. A snapshot carries everything under it, so there is no way to
# take one change and leave its neighbour: the newest merge that has soaked fixes the commit,
# and a hold, rollback or hotfix signal on *any* change under that commit stops the stage.
# The alternative -- promoting around a held change -- is not available, because the commit
# containing it is an ancestor of every commit after it.
promote_by_snapshot() {
  local index previous next soak_seconds eligible_sha eligible_pr merged_epoch age
  local pr merged_at oid had_merge snapshot_branch short carried blocked blockers issue entry
  local -a commits issues

  for index in "${!stages[@]}"; do
    [ "$index" -gt 0 ] || continue
    previous="${stages[index - 1]}"
    next="${stages[index]}"

    note "── ${previous} → ${next} ─────────────────────────────────────────"

    # One promotion per target at a time (FR-031). The same rule and the same marker as the
    # cherry-picking path: two snapshots of the same stage open at once would each carry the
    # other's contents, and whichever merged second would carry a change the first never saw.
    open_promotion="$(gh pr list --repo "$REPO" --state open --base "$next" --json number,body \
      --jq "[.[] | select((.body // \"\") | contains(\"<!-- promotion-pr: ${next}: \"))][0].number // empty")"
    if [ -n "$open_promotion" ]; then
      note "Promotion pull request #${open_promotion} into ${next} is still open; nothing else goes to ${next} until it lands."
      skipped_because "already-present"
      continue
    fi

    git fetch --no-tags origin "${previous}:refs/remotes/origin/${previous}" "${next}:refs/remotes/origin/${next}" >/dev/null 2>&1 || true

    soak_seconds="$(duration_seconds "$(soak_for "$next")")"

    # The newest merge into the stage below that has rested long enough, and the commit it
    # produced. Newest first and the first soaked one wins: an older commit would leave the
    # merges above it behind for no reason, and a newer one has not soaked.
    #
    # Deliberately not filtered to the bot's own pull requests, unlike the cherry-picking
    # path. A snapshot is a picture of the branch, so a person's merge into `dev` is in it
    # whether or not this route was told about it; pretending otherwise would promote work
    # while reporting that it had not.
    eligible_sha=""
    eligible_pr=""
    had_merge=0
    while IFS=$'\t' read -r pr merged_at oid; do
      [ -n "$oid" ] || continue
      had_merge=1
      merged_epoch="$(date -u -d "$merged_at" +%s 2>/dev/null || echo 0)"
      age=$(( $(date -u +%s) - merged_epoch ))
      if [ "$merged_epoch" -gt 0 ] && [ "$age" -lt "$soak_seconds" ]; then
        note "PR #${pr} merged into ${previous} $((age / 60))m ago, and ${next} asks for $((soak_seconds / 60))m."
        continue
      fi
      eligible_sha="$oid"
      eligible_pr="$pr"
      break
    done < <(gh pr list --repo "$REPO" --state merged --base "$previous" --limit 50 \
      --json number,mergedAt,mergeCommit \
      --jq 'sort_by(.mergedAt) | reverse | .[] | [.number, .mergedAt, (.mergeCommit.oid // "")] | @tsv')

    if [ -z "$eligible_sha" ]; then
      if [ "$had_merge" -eq 1 ]; then
        note "Nothing on ${previous} has rested long enough for ${next}."
        skipped_because "soak-pending"
      else
        note "Nothing has merged into ${previous}; there is nothing to snapshot."
        skipped_because "no-eligible-change"
      fi
      continue
    fi

    # Fetched before it is named: a checkout brings down what the run needs and nothing
    # else, and handing an unfetched sha to git exits 128 and takes the route with it. The
    # same failure that killed promotion under squash the first time a repository used it.
    git fetch --no-tags --quiet origin "$eligible_sha" 2>/dev/null || true
    if ! git cat-file -e "${eligible_sha}^{commit}" 2>/dev/null; then
      note "::warning::${eligible_sha:0:8} is not readable in this checkout; leaving ${next} alone."
      skipped_because "no-eligible-change"
      continue
    fi

    # The cheap answer first: the stage above literally has this commit, which is what a
    # merge-method promotion leaves behind. It is only ever a fast path -- under `rebase` and
    # `squash` the forge mints new identifiers for the same content, so the commits this
    # promotion carried are on `${next}` and are ancestors of nothing here (FR-032).
    if git merge-base --is-ancestor "$eligible_sha" "refs/remotes/origin/${next}" 2>/dev/null; then
      note "${next} already contains ${eligible_sha:0:8}; there is nothing to carry."
      skipped_because "already-present"
      continue
    fi

    # What the snapshot carries: every non-merge commit the stage above does not have. This
    # is the enumeration the promotion pull request declares, and it is read from git rather
    # than from the forge, because the forge's answer is per pull request and the question
    # here is about a range.
    mapfile -t commits < <(git rev-list --reverse --no-merges \
      "refs/remotes/origin/${next}..${eligible_sha}" 2>/dev/null || true)
    if [ "${#commits[@]}" -eq 0 ]; then
      note "${next} is level with ${eligible_sha:0:8}; nothing to carry."
      skipped_because "already-present"
      continue
    fi

    # And now the question the range cannot answer: has this snapshot already been promoted?
    #
    # `base..head` is about ancestry, and a promotion merged under `rebase` or `squash` left
    # `${next}` holding the same changes under different identifiers. Every commit is then
    # still "ahead" of the stage above, so a route that stopped at the range would open the
    # same promotion again every time the clock fired, for the rest of the repository's life.
    #
    # Patch-ids -- which is how the cherry-picking path answers this -- cannot help here
    # either, and it is worth saying why, because it is the obvious fix and it does not work.
    # That path promotes one change at a time, so under `squash` the forge's single commit is
    # the change and its patch-id matches. A snapshot carries many commits, and `squash`
    # collapses all of them into one whose patch-id matches none of the originals. A snapshot
    # is also all-or-nothing, so "some of this content is present" is not an answer to
    # anything (FR-031, FR-032).
    #
    # So the forge is asked, as it is for every other question this route cannot answer from
    # a working copy: is there a merged promotion pull request into this stage whose marker
    # names this commit? That holds under all three merge methods, because it is a fact about
    # what the route did rather than about what the merge left behind.
    if [ -n "$(gh pr list --repo "$REPO" --state merged --base "$next" --limit 50 --json number,body \
      --jq "[.[] | select((.body // \"\") | contains(\"<!-- promotion-snapshot: ${next}: ${eligible_sha} -->\"))][0].number // empty")" ]; then
      note "${eligible_sha:0:8} has already been promoted into ${next}; the merge rewrote its commits, which is why they still read as ahead."
      skipped_because "already-present"
      continue
    fi

    mapfile -t issues < <(issues_behind "${commits[@]}")
    if [ "${#issues[@]}" -eq 0 ]; then
      note "::warning::The ${#commits[@]} commit(s) ${previous} has ahead of ${next} belong to no issue this loop knows, so nothing would be labelled or closed when they land. Leaving ${next} to a person."
      skipped_because "no-eligible-change"
      continue
    fi

    # Any signal on any carried change stops the stage. A snapshot cannot leave one commit
    # behind, so "promote the others" is not a thing this strategy can do, and a route that
    # carried a held change because four other changes were ready would be defeating the
    # hold rather than honouring it.
    #
    # A revert needs no arm of its own here, unlike the cherry-picking path: the revert
    # commit is itself under the snapshot, so it travels with the change it undoes and the
    # stage above ends up in the state the stage below is actually in.
    # Every blocker, not the first one found.
    #
    # Stopping at the first is what a per-change strategy would do, because there the answer
    # is about that change. Here the answer is about the stage: nothing leaves `${previous}`
    # until every one of these is cleared, so a person who clears the one the route named
    # comes back to find the stage still frozen, with a different name on it. Observed on the
    # canary, 21/09/2026: two labels left by earlier sessions, reported one at a time, and in
    # between them the pipeline looked like it had a new problem rather than the same one.
    blocked=""
    blockers=""
    for issue in "${issues[@]}"; do
      for entry in "${HOLD_LABEL:-}" "${ROLLBACK_LABEL:-}" "${HOTFIX_LABEL:-}"; do
        [ -n "$entry" ] || continue
        if has_label "$issue" "$entry"; then
          blockers="${blockers}
- #${issue} carries \`${entry}\`"
          # The first one decides the outcome code, because the enumeration has one slot and
          # the ranking in `skipped_because` already says which kind most wants a person.
          [ -n "$blocked" ] || blocked="$entry"
          break
        fi
      done
    done
    if [ -n "$blocked" ]; then
      note "::warning::${next} is frozen: a promotion carries a snapshot of ${previous} and cannot leave any of these behind.${blockers}"
      note "Nothing moves out of ${previous} until every one of them is cleared."
      case "$blocked" in
        "${ROLLBACK_LABEL:-}") skipped_because "rollback" ;;
        "${HOTFIX_LABEL:-}") skipped_because "hotfix" ;;
        *) skipped_because "hold" ;;
      esac
      continue
    fi

    # The template's own braces are quoted rather than backslash-escaped, and the default is
    # a statement of its own: `${VAR:-promote/{stage}-{sha}}` reads its default as far as the
    # first `}` it can, which produced `promote/test-<sha>-<sha>}` and a name the branch-write
    # guard then refused -- correctly, and for the wrong reason.
    short="${eligible_sha:0:8}"
    snapshot_branch="${SNAPSHOT_BRANCH_TEMPLATE:-}"
    [ -n "$snapshot_branch" ] || snapshot_branch='promote/{stage}-{sha}'
    snapshot_branch="${snapshot_branch//"{stage}"/"$next"}"
    snapshot_branch="${snapshot_branch//"{sha}"/"$short"}"

    # A head from a previous attempt, still there.
    #
    # Reached only once the content check above has said there is still something to carry,
    # which is what makes this case what it sounds like: a promotion that was opened and not
    # merged. A merged one leaves its head behind too -- no code path deletes a branch
    # (FR-029) -- and answering `already-present` above is the difference between a quiet
    # correct run and a warning every half hour for the rest of the week.
    #
    # Nothing is force-pushed under this strategy, so the route does not get to decide what
    # happens to it: FR-051 put a hold on the changes when the promotion was closed, and the
    # branch is a person's to remove.
    if git ls-remote --exit-code --heads origin "$snapshot_branch" >/dev/null 2>&1; then
      note "::warning::${snapshot_branch} already exists on the forge and ${previous} still has content ${next} does not, so a promotion from this commit was opened and not merged. Nothing is force-pushed under env-promotion; ${next} waits until somebody removes that branch or the stage moves on."
      skipped_because "already-present"
      continue
    fi

    # The deny-list applies to what this job is about to write, exactly as it does to an
    # agent's push: a stage, the branch point or a release branch is never a promotion head
    # (FR-063). It is the snapshot template's job to produce a name this allows.
    if ! BRANCH="$snapshot_branch" \
      DENIED_BRANCHES="${STAGE_BRANCHES}" \
      RELEASE_PATTERN="${RELEASE_PATTERN:-}" \
      BRANCH_PATTERN="${PROMOTION_BRANCH_PATTERN:-^promote/}" \
      DEFAULT_BRANCH="${DEFAULT_BRANCH:-}" \
      bash "${GITHUB_ACTION_PATH}/../guard-branch-write/guard-branch-write.sh"; then
      note "Refusing to write ${snapshot_branch}; nothing done for ${next}."
      continue
    fi

    git switch --detach "$eligible_sha" >/dev/null 2>&1

    # One changelog entry per carried issue, riding the head before the push, as under the
    # cherry-picking path: an entry pushed to the stage branch would be this route writing a
    # protected branch directly (FR-031). A changelog that cannot be written does not stop a
    # promotion; the record is not the change.
    for issue in "${issues[@]}"; do
      if ! STAGE="$next" \
        ISSUE_NUMBER="$issue" \
        COMMIT_SHA="$(git rev-parse HEAD)" \
        HEAD_BRANCH="" \
        MAX_ENTRIES="${MAX_ENTRIES:-20}" \
        GIT_IDENTITY="${GIT_IDENTITY:-$(git config user.name)}" \
        bash "${GITHUB_ACTION_PATH}/../update-changelog/update-changelog.sh"; then
        note "::warning::Issue #${issue}: the changelog entry for ${next} could not be written; promoting without it."
      fi
    done

    # No lease and no force: the branch is new, and a name that already existed was refused
    # above. A snapshot that could be force-pushed would be a moving head again, which is
    # the thing this strategy exists to avoid.
    git push origin "HEAD:refs/heads/${snapshot_branch}"

    # One marker per carried issue, which is what FR-051 reads to label and close every one
    # of them, and what the gate reads to check each carries the stage below's label
    # (FR-056). The promotion marker names the stage and the pull request that produced the
    # eligible commit, in the grammar every existing reader already matches.
    carried=""
    for issue in "${issues[@]}"; do
      carried="${carried}
<!-- implement-issue: ${issue} -->"
    done

    # The snapshot marker names the commit rather than a pull request, and it is what makes
    # a second promotion of the same commit answerable after the first one has merged and
    # the merge method has rewritten every sha it carried.
    body="Promotes \`${previous}\` to \`${next}\` as of \`${eligible_sha:0:8}\`.

This is a snapshot, not \`${previous}\` itself: anything merged into \`${previous}\` after this pull request opened is not in it, and travels on the next promotion.

It carries ${#commits[@]} commit(s) and ${#issues[@]} issue(s): $(printf '#%s ' "${issues[@]}")
${carried}
<!-- promotion-pr: ${next}: ${eligible_pr} -->
<!-- promotion-snapshot: ${next}: ${eligible_sha} -->"

    new_pr="$(gh pr create --repo "$REPO" --base "$next" --head "$snapshot_branch" \
      --title "${TITLE_PREFIX:-[bot] }promote ${previous} to ${next}" --body "$body" |
      grep -oE '[0-9]+$' || true)"

    note "Opened promotion pull request #${new_pr:-?} into ${next}, carrying ${#issues[@]} issue(s)."
    promoted=$((promoted + 1))
    reason="promoted"
  done
}

if [ "${BRANCH_STRATEGY:-}" = "env-promotion" ]; then
  promote_by_snapshot
  report_and_exit
fi

for index in "${!stages[@]}"; do
  [ "$index" -gt 0 ] || continue
  previous="${stages[index - 1]}"
  next="${stages[index]}"

  note "── ${previous} → ${next} ─────────────────────────────────────────"

  soak_seconds="$(duration_seconds "$(soak_for "$next")")"

  # One change at a time per target (FR-033). A stage that takes two promotions at once gets
  # two pull requests built on the same tip: whichever merges second carries a change the
  # first one never saw, and the order they land in becomes whoever's CI finished first
  # rather than the order the work was done in. So a target with a promotion still open is a
  # target this run leaves alone, and the change behind it goes when that one lands.
  #
  # Matched on the promotion marker and this stage's name, which only this route writes: an
  # agent's own pull request opens against the first stage, which is never a target here.
  open_promotion="$(gh pr list --repo "$REPO" --state open --base "$next" --json number,body \
    --jq "[.[] | select((.body // \"\") | contains(\"<!-- promotion-pr: ${next}: \"))][0].number // empty")"
  if [ -n "$open_promotion" ]; then
    note "Promotion pull request #${open_promotion} into ${next} is still open; nothing else goes to ${next} until it lands."
    skipped_because "already-present"
    continue
  fi

  # The changes that landed on the previous stage, oldest first: a promotion that jumps the
  # queue puts a later change on a stage before the one it was built on (FR-033).
  while IFS=$'\t' read -r pr merged_at; do
    [ -n "$pr" ] || continue

    issue="$(pr_issue "$pr")"
    if [ -z "$issue" ]; then
      note "PR #${pr}: no issue this loop knows; leaving it alone."
      continue
    fi

    if has_label "$issue" "${HOLD_LABEL:-}"; then
      note "Issue #${issue} carries ${HOLD_LABEL}; not promoting."
      skipped_because "hold"
      continue
    fi
    if has_label "$issue" "${ROLLBACK_LABEL:-}"; then
      note "Issue #${issue} carries ${ROLLBACK_LABEL}; not promoting."
      skipped_because "rollback"
      continue
    fi
    if has_label "$issue" "${HOTFIX_LABEL:-}"; then
      note "Issue #${issue} carries ${HOTFIX_LABEL}; it takes its own path."
      skipped_because "hotfix"
      continue
    fi

    merged_epoch="$(date -u -d "$merged_at" +%s 2>/dev/null || echo 0)"
    age=$(( $(date -u +%s) - merged_epoch ))
    if [ "$merged_epoch" -gt 0 ] && [ "$age" -lt "$soak_seconds" ]; then
      note "Issue #${issue}: $((age / 60))m on ${previous}, and ${next} asks for $((soak_seconds / 60))m."
      skipped_because "soak-pending"
      continue
    fi

    promotion_branch="promote/${next}-${issue}-${GITHUB_RUN_ID:-0}"

    # The deny-list applies to what this job is about to write, exactly as it does to an
    # agent's push: a stage, the branch point or a release branch is never a promotion head
    # (FR-063).
    if ! BRANCH="$promotion_branch" \
      DENIED_BRANCHES="${STAGE_BRANCHES}" \
      RELEASE_PATTERN="${RELEASE_PATTERN:-}" \
      BRANCH_PATTERN="${PROMOTION_BRANCH_PATTERN:-^promote/}" \
      DEFAULT_BRANCH="${DEFAULT_BRANCH:-}" \
      bash "${GITHUB_ACTION_PATH}/../guard-branch-write/guard-branch-write.sh"; then
      note "Refusing to write ${promotion_branch}; nothing done for issue #${issue}."
      continue
    fi

    git fetch --no-tags origin "${previous}:refs/remotes/origin/${previous}" "${next}:refs/remotes/origin/${next}" >/dev/null 2>&1 || true

    mapfile -t commits < <(identify_commits "$pr")
    if [ "${#commits[@]}" -eq 0 ]; then
      note "PR #${pr} yields no commits under ${MERGE_METHOD:-rebase}; leaving issue #${issue} where it is."
      continue
    fi

    # Two filters, both by content. The branch point's history is excluded because under a
    # chain the work was cut from it and merged back into it, so its own commits are
    # reachable from the pull request and are not this change (FR-032). The next stage's is
    # excluded because a re-run must not duplicate what it already carried across.
    mapfile -t present < <(
      patch_ids_of "refs/remotes/origin/${next}"
      # ...unless the branch point is the first stage, where it is the stage a change is
      # promoted *from* and its commits are the change itself. Excluding it there would
      # filter out everything and no change would ever travel, which is why that shape used
      # to be refused outright rather than defaulted to (FR-086).
      if [ -n "${BRANCH_POINT:-}" ] && [ "${BRANCH_POINT}" != "${stages[0]:-}" ]; then
        patch_ids_of "refs/remotes/origin/${BRANCH_POINT}"
      fi
    )

    to_pick=()
    change_ids=()
    for sha in "${commits[@]}"; do
      pid="$(git show "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
      [ -z "$pid" ] || change_ids+=("$pid")
      already=false
      for known in "${present[@]}"; do
        if [ -n "$pid" ] && [ "$pid" = "$known" ]; then
          already=true
          break
        fi
      done
      [ "$already" = true ] || to_pick+=("$sha")
    done

    # Everything the previous stage has that the next one does not, *besides this change*:
    # what the promotion is leaving behind (T238). After `change_ids`, because the change's
    # own commits are the one thing that is not a gap -- computing this earlier counted the
    # change itself and every promotion claimed to be leaving something behind.
    outstanding=()
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      other_id="$(git show "$other" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
      [ -n "$other_id" ] || continue
      seen=false
      for known in "${present[@]}" "${change_ids[@]}"; do
        [ "$other_id" != "$known" ] || { seen=true; break; }
      done
      [ "$seen" = true ] || outstanding+=("- \`$(git log -1 --format=%h "$other")\` $(git log -1 --format=%s "$other")")
    done < <(git log --no-merges --reverse --format=%H \
      "refs/remotes/origin/${next}..refs/remotes/origin/${previous}" 2>/dev/null | head -n 20)

    # Asked before "is there anything left to carry", because a change that was reverted on
    # the previous stage after an earlier promotion must stop travelling too: labelling it
    # here is what stops the next stage in the chain from taking it (FR-053).
    if [ "${#change_ids[@]}" -gt 0 ] && reverted="$(was_rolled_back "$previous" "${change_ids[@]}")"; then
      note "::warning::Issue #${issue} was reverted on ${previous} by ${reverted:0:8}; not promoting it to ${next}."
      # The comment is written once: the label it adds is checked before any of this on the
      # next run, so a rollback is announced rather than repeated every time the cron fires.
      if gh issue edit "$issue" --repo "$REPO" --add-label "${ROLLBACK_LABEL:-}" >/dev/null 2>&1; then
        gh issue comment "$issue" --repo "$REPO" --body "This change was reverted on \`${previous}\` by ${reverted:0:8}, so the promotion route has stopped carrying it and has marked it \`${ROLLBACK_LABEL}\`. Remove the label when the change is meant to travel again." >/dev/null 2>&1 || true
      fi
      skipped_because "rollback"
      continue
    fi

    if [ "${#to_pick[@]}" -eq 0 ]; then
      note "Issue #${issue}: every commit is already on ${next}."
      skipped_because "already-present"
      continue
    fi

    git switch --detach "refs/remotes/origin/${next}" >/dev/null 2>&1
    git switch -c "$promotion_branch" >/dev/null 2>&1

    picked=true
    conflict_sha=""
    conflict_files=""
    for sha in "${to_pick[@]}"; do
      if git cherry-pick "$sha" >/dev/null 2>&1; then
        continue
      fi
      # A cherry-pick that leaves nothing staged is a change already present by another
      # route -- a hotfix, a manual carry -- and not a conflict. Skipping it is the same
      # answer the patch-id filter gives, one step later, and is why a re-run neither
      # duplicates nor fails (FR-032).
      if git diff --cached --quiet 2>/dev/null && git diff --quiet 2>/dev/null; then
        git cherry-pick --skip >/dev/null 2>&1 || git cherry-pick --abort >/dev/null 2>&1 || true
        continue
      fi
      # Which commit, and which files: read before the abort, because the abort is what
      # throws the answer away. A hand-off that says only "it conflicts" leaves the person
      # to find out where, which is the whole of the work.
      conflict_sha="$sha"
      conflict_files="$(git diff --name-only --diff-filter=U 2>/dev/null | head -n 20 | tr '\n' ' ')"
      git cherry-pick --abort >/dev/null 2>&1 || true
      picked=false
      break
    done

    if [ "$picked" != true ]; then
      # Nothing has been pushed: the promotion branch exists only in this checkout, the
      # previous stage is untouched, and the change's own branch is where it was. The
      # cherry-pick was aborted, so the index is clean and the run can carry on with the
      # next target (FR-034).
      #
      # No agent is asked to resolve it. Under rebase the forge replays each commit onto
      # the base and cannot replay a merge commit, so the only resolution an agent could
      # push -- merging the target in -- is the one FR-027 forbids: it would be dropped at
      # merge time and the conflict would come back. Under any method the agent's push is a
      # bundle applied fast-forward only, and a resolution is not a fast-forward.
      conflict_subject="$(git log -1 --format=%s "$conflict_sha" 2>/dev/null || true)"
      note "::warning::Issue #${issue}: ${conflict_sha:0:8} does not apply onto ${next}; handing it to a person."

      # `hold` before the comment: the label is what stops the next run trying again, and a
      # comment without it would be a repeated apology every time the cron fires.
      gh issue edit "$issue" --repo "$REPO" --add-label "${HOLD_LABEL:-}" >/dev/null 2>&1 || true
      gh issue comment "$issue" --repo "$REPO" --body "Promotion to \`${next}\` stopped: \`${conflict_sha:0:8}\` (${conflict_subject:-no subject}) does not apply cleanly.

Conflicting files: ${conflict_files:-not recorded}

Nothing was pushed. \`${previous}\` and this change's own branch are exactly as they were, and the issue now carries \`${HOLD_LABEL:-hold}\`, which is what keeps the route from trying this again on the next run.

Carrying it across is a person's job: no agent is asked to resolve a promotion conflict, because the only resolution one could push is a merge of the target branch, and under a replaying merge method that resolution is dropped and the conflict returns. Remove \`${HOLD_LABEL:-hold}\` when the change is ready to travel again."
      skipped_because "conflict-handed-off"
      git switch --detach "refs/remotes/origin/${next}" >/dev/null 2>&1 || true
      continue
    fi

    # The changelog entry rides the head, before the push: one branch, one push, one pull
    # request, and no entry on a branch whose promotion then failed to open. Which stages get
    # one is the profile's answer and the script's to check (FR-023).
    #
    # A changelog that cannot be written does not stop a promotion: the entry is a record of
    # the change, and refusing to move the change because the record failed is the wrong way
    # round. It is a warning on the run either way.
    if ! STAGE="$next" \
      ISSUE_NUMBER="$issue" \
      COMMIT_SHA="$(git rev-parse HEAD)" \
      HEAD_BRANCH="" \
      MAX_ENTRIES="${MAX_ENTRIES:-20}" \
      GIT_IDENTITY="${GIT_IDENTITY:-$(git config user.name)}" \
      bash "${GITHUB_ACTION_PATH}/../update-changelog/update-changelog.sh"; then
      note "::warning::Issue #${issue}: the changelog entry for ${next} could not be written; promoting without it."
    fi

    git push --force-with-lease origin "HEAD:refs/heads/${promotion_branch}"

    # What else `${previous}` has that `${next}` does not, besides this change.
    #
    # A promotion carries the commits of the change it was asked to carry and nothing else,
    # which is the rule that keeps ungated work away from production. The cost of that rule
    # is that a change built on something which arrived outside the loop -- a person's pull
    # request, a configuration push -- travels without it and fails to build on arrival,
    # with nothing connecting the two facts. That is exactly what happened to #47 on the
    # canary: the components went, `@mui/material` stayed, and CI reported forty unresolved
    # imports (T238).
    #
    # Named, never carried. Work waiting to be promoted is the normal state of a chain, so
    # this is a note rather than a warning, and it is written only when there is something
    # to say.
    context=""
    if [ "${#outstanding[@]}" -gt 0 ]; then
      context="

**\`${next}\` is also missing ${#outstanding[@]} other commit(s) that \`${previous}\` has**, which this promotion does not carry: a promotion carries the change it was asked to carry and nothing else. If the checks below fail on something this change did not touch, that is the first place to look.

$(printf '%s\n' "${outstanding[@]}")

Promote them, or carry them across deliberately. Nothing here is wrong on its own: work waiting on an earlier stage is the ordinary state of a chain."
    fi

    body="Promotes the change from \`${previous}\` to \`${next}\`.${context}

<!-- implement-issue: ${issue} -->
<!-- promotion-pr: ${next}: ${pr} -->"
    new_pr="$(gh pr create --repo "$REPO" --base "$next" --head "$promotion_branch" \
      --title "${TITLE_PREFIX:-[bot] }promote #${issue} to ${next}" --body "$body" |
      grep -oE '[0-9]+$' || true)"

    note "Issue #${issue}: opened promotion pull request #${new_pr:-?} into ${next}."
    promoted=$((promoted + 1))
    reason="promoted"
    # This target is busy now, and the changes behind this one keep their order by waiting:
    # the next run finds this pull request open and leaves the stage alone until it lands.
    break
  done < <(gh pr list --repo "$REPO" --state merged --base "$previous" --limit 50 \
    --json number,mergedAt,author \
    --jq '[.[] | select(.author.is_bot)] | sort_by(.mergedAt) | .[] | [.number, .mergedAt] | @tsv')
done

report_and_exit
