#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/update-changelog/fold-target-changelog.sh. Profile digest: dee2c3b90207. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Fold the target stage's changelog into a snapshot promotion head (env-promotion), so the
# promotion pull request does not conflict on it.
#
# Under env-promotion a promotion head is a snapshot of the stage below, and the changelog
# entries for the stage above ride that head. Merged, they land on the stage above and nowhere
# else, so the stage below never has them. The next snapshot prepends its own entries to the
# stage below's older copy of the file while the stage above has already prepended the last
# promotion's: both sides changed the top of the same array, and every promotion after the
# first conflicted on the changelog alone (loopscope #279, 22/11/2026).
#
# When the target has moved on from the snapshot in the changelog and in nothing else, this
# makes a merge commit whose parents are the snapshot and the target, and whose tree is the
# snapshot's with the changelog set to the union of both sides' entries: deduplicated on
# (issue, commit), newest first, capped. Deterministic and with no merge machinery, so there is
# nothing for a model or a person to resolve. It needs the merge commit to survive, which only
# `mergeMethod: merge` guarantees -- the method env-promotion needs anyway -- so the caller
# runs it only then. A target that differs in anything else is left alone: the pull request
# shows that conflict as before, and it is a person's.
#
# Run on the detached snapshot head, before the entries are written. Reads:
#   TARGET_REF       the target stage's remote-tracking ref, e.g. refs/remotes/origin/main
#   CHANGELOG_PATH   the changelog file; empty means none is kept
#   MAX_ENTRIES      newest entries to keep (default 20)
#   GIT_IDENTITY     the commit's author
set -euo pipefail

path="${CHANGELOG_PATH:-}"
[ -n "$path" ] || exit 0
git rev-parse --verify --quiet "${TARGET_REF}^{commit}" >/dev/null || exit 0

base="$(git merge-base HEAD "$TARGET_REF" 2>/dev/null || true)"
[ -n "$base" ] || exit 0
# What the target changed since the two parted, and of that, what the snapshot does not already
# have. A file both sides changed to the same content -- a reinstall landed on every stage as its
# own commit, which is how the loop is installed -- is not a divergence. Counting it was why the
# fold never fired on loopscope #307 (22/11/2026): thirteen installed files had changed on main,
# every one identical to the snapshot's, and the changelog alone differed.
changed="$(git diff --name-only "$base" "$TARGET_REF")"
[ -n "$changed" ] || exit 0
missing=""
while IFS= read -r file; do
  [ -n "$file" ] && [ "$file" != "$path" ] || continue
  git diff --quiet HEAD "$TARGET_REF" -- "$file" || missing="${missing} ${file}"
done <<<"$changed"
if [ -n "$missing" ]; then
  echo "${TARGET_REF#refs/remotes/origin/} has changes the snapshot does not besides ${path} (${missing# }); leaving them to the pull request."
  exit 0
fi
case $'\n'"$changed"$'\n' in *$'\n'"$path"$'\n'*) ;; *) exit 0 ;; esac
git diff --quiet HEAD "$TARGET_REF" -- "$path" && exit 0

ours="$(git show "HEAD:${path}" 2>/dev/null || echo '{}')"
theirs="$(git show "${TARGET_REF}:${path}" 2>/dev/null || echo '{}')"
folded="$(jq -n --argjson n "${MAX_ENTRIES:-20}" --argjson ours "$ours" --argjson theirs "$theirs" '
  $ours
  | .changes = ([($ours.changes // [])[], ($theirs.changes // [])[]]
      | unique_by([.issue, .commit])
      | sort_by(.timestamp // "") | reverse
      | .[:$n])')"

printf '%s\n' "$folded" > "$path"
git add -- "$path"
tree="$(git write-tree)"
author="${GIT_IDENTITY:-$(git config user.name)}"
commit="$(GIT_AUTHOR_NAME="$author" GIT_AUTHOR_EMAIL="${author}@users.noreply.github.com" \
  GIT_COMMITTER_NAME="$author" GIT_COMMITTER_EMAIL="${author}@users.noreply.github.com" \
  git commit-tree "$tree" -p HEAD -p "$TARGET_REF" \
  -m "Merge ${TARGET_REF#refs/remotes/origin/}'s changelog into the promotion head")"
git reset --quiet --soft "$commit"
echo "Folded ${TARGET_REF#refs/remotes/origin/}'s ${path} into the promotion head (${commit:0:8})."
