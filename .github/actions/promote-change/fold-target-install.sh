#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/promote-change/fold-target-install.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Fold the target stage's loop install into a snapshot promotion head, so the promotion pull
# request does not conflict on files the loop installs (feature 007 FR-129).
#
# The loop is installed stage by stage, each as its own pull request. A promotion snapshot of the
# stage below taken before the stage above was reinstalled carries the older install, both sides
# have changed the same installed files, and the pull request conflicts on every compiled lock --
# loopscope #382, 23/11/2026, where only a person could resolve it. A reinstall replaces the whole
# set at once, so there is one right answer: the newer install, file for file. This makes a merge
# commit whose parents are the snapshot and the target and whose tree is the snapshot's, with
# every installed file the two disagree on taken from the side that installed last, and the
# changelog, when it too differs, set to the union of both sides' entries as the changelog fold
# does. Deterministic, with no merge machinery and nothing for a model or a person to resolve.
#
# Installed means compiled (`*.lock.yml`, anything under `.github/aw/`) or carrying a package
# ownership header ("Managed by") on either side. When the target has moved on in anything else
# -- application code, a hotfix -- nothing is done and the pull request shows that conflict to a
# person, as before. Like the changelog fold, it needs the merge commit to survive, which only
# `mergeMethod: merge` guarantees, so the caller runs it only then.
#
# Run on the detached snapshot head, before the changelog fold. Reads:
#   TARGET_REF       the target stage's remote-tracking ref, e.g. refs/remotes/origin/test
#   CHANGELOG_PATH   the changelog file; empty means none is kept
#   MAX_ENTRIES      newest changelog entries to keep (default 20)
#   GIT_IDENTITY     the commit's author
set -euo pipefail

: "${TARGET_REF:?fold-target-install: TARGET_REF is required}"
target="$(git rev-parse --verify --quiet "${TARGET_REF}^{commit}" || true)"
[ -n "$target" ] || exit 0
# The commit, not the ref, wherever a path follows a colon: `<ref>:<path>` with a slash in the ref
# reads as a path list to some shells (Git Bash), which rewrote it and found no file at all.
base="$(git merge-base HEAD "$TARGET_REF" 2>/dev/null || true)"
[ -n "$base" ] || exit 0
changed="$(git diff --name-only "$base" "$TARGET_REF")"
[ -n "$changed" ] || exit 0

path="${CHANGELOG_PATH:-}"
target_name="${TARGET_REF#refs/remotes/origin/}"

is_installed() {
  case "$1" in
    *.lock.yml | .github/aw/*) return 0 ;;
  esac
  local ref
  for ref in HEAD "$target"; do
    # sed reads to the end: `head` closes the pipe early, and under pipefail a large file's
    # `git show` then fails with SIGPIPE and the check says no (the router, on loopscope #382).
    if git show "${ref}:$1" 2>/dev/null | sed -n '1,3p' | grep -q "Managed by "; then return 0; fi
  done
  return 1
}

installed=()
other=""
changelog_differs=false
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # The same content on both sides -- an install that landed on each stage alike -- is no
  # divergence at all.
  git diff --quiet HEAD "$TARGET_REF" -- "$file" && continue
  if [ -n "$path" ] && [ "$file" = "$path" ]; then
    changelog_differs=true
  elif is_installed "$file"; then
    installed+=("$file")
  else
    other="${other} ${file}"
  fi
done <<<"$changed"

if [ -n "$other" ]; then
  echo "${target_name} has changes the snapshot does not besides the loop's install (${other# }); leaving them to the pull request."
  exit 0
fi
# Nothing of the install differs: a changelog alone is the changelog fold's.
[ "${#installed[@]}" -gt 0 ] || exit 0

# The side that installed last, by the newest commit that touched any of these files.
ours_at="$(git log -1 --format=%ct HEAD -- "${installed[@]}" 2>/dev/null || echo 0)"
theirs_at="$(git log -1 --format=%ct "$TARGET_REF" -- "${installed[@]}" 2>/dev/null || echo 0)"
winner=HEAD
if [ "${theirs_at:-0}" -ge "${ours_at:-0}" ]; then winner="$TARGET_REF"; fi

if [ "$winner" = "$TARGET_REF" ]; then
  for file in "${installed[@]}"; do
    if git cat-file -e "${target}:${file}" 2>/dev/null; then
      git checkout --quiet "$target" -- "$file"
    else
      git rm --quiet --cached --ignore-unmatch -- "$file"
      rm -f -- "$file"
    fi
  done
fi

if [ "$changelog_differs" = true ]; then
  ours="$(git show "HEAD:${path}" 2>/dev/null || echo '{}')"
  theirs="$(git show "${target}:${path}" 2>/dev/null || echo '{}')"
  jq -n --argjson n "${MAX_ENTRIES:-20}" --argjson ours "$ours" --argjson theirs "$theirs" '
    $ours
    | .changes = ([($ours.changes // [])[], ($theirs.changes // [])[]]
        | unique_by([.issue, .commit])
        | sort_by(.timestamp // "") | reverse
        | .[:$n])' >"$path"
  git add -- "$path"
fi

if [ "$winner" = HEAD ]; then from="the snapshot"; else from="$target_name"; fi
tree="$(git write-tree)"
author="${GIT_IDENTITY:-$(git config user.name)}"
message="Merge ${target_name}'s loop install into the promotion head (the newer install is ${from}'s)"
commit="$(GIT_AUTHOR_NAME="$author" GIT_AUTHOR_EMAIL="${author}@users.noreply.github.com" \
  GIT_COMMITTER_NAME="$author" GIT_COMMITTER_EMAIL="${author}@users.noreply.github.com" \
  git commit-tree "$tree" -p HEAD -p "$TARGET_REF" -m "$message")"
git reset --quiet --soft "$commit"
echo "Folded ${target_name}'s loop install into the promotion head (${commit:0:8}); ${#installed[@]} installed file(s) taken from ${from}."
