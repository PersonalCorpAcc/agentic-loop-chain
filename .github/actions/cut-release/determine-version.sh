#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/cut-release/determine-version.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The version this release cuts. Writes `current_version` and `new_version` to GITHUB_OUTPUT
# and copies the agent's notes to NOTES_OUT for the release step.
#
# VERSION_BUMP is `major`, `minor`, `patch` or `auto`. Under `auto` a breaking change in the
# notes or a `type!:` or `type(scope)!:` commit is major, a `feat:` commit is minor, and anything else a patch.
# Fails when the agent wrote no notes, or for a bump or version source it does not know.
#
# Environment: VERSION_SOURCE, VERSION_BUMP, AGENT_DIR (default /tmp/gh-aw/agent), NOTES_OUT
# (default /tmp/release-notes.md), GITHUB_OUTPUT. Run from the repository root.

set -euo pipefail

# shellcheck source=SCRIPTDIR/read-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/read-version.sh"

agent_dir="${AGENT_DIR:-/tmp/gh-aw/agent}"
notes="$agent_dir/release-notes.md"
if [ ! -f "$notes" ]; then
  echo "::error::Agent did not write release-notes.md"
  exit 1
fi

read_version
current="$version"
echo "current_version=$current" >> "$GITHUB_OUTPUT"

# The log is `git log --oneline`, so every subject follows an abbreviated hash. Matched from the
# line's start, `feat:` never matched and `type!:` was spelt `type(!:`, so auto cut a patch
# for every release until the bump was first run under test (FR-086).
bump="$VERSION_BUMP"
if [ "$bump" = "auto" ]; then
  if grep -qiE 'BREAKING CHANGE' "$notes" || grep -qE '^[0-9a-f]+ [a-z]+(\([^)]*\))?!:' "$agent_dir/git-log.txt"; then
    bump="major"
  elif grep -qE '^[0-9a-f]+ feat(\([^)]*\))?:' "$agent_dir/git-log.txt"; then
    bump="minor"
  else
    bump="patch"
  fi
fi

IFS='.' read -r major minor patch <<< "$current"
case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "::error::Unknown version-bump: $bump"; exit 1 ;;
esac
new_version="${major}.${minor}.${patch}"
echo "new_version=$new_version" >> "$GITHUB_OUTPUT"
echo "Determined version: $current -> $new_version (bump: $bump)"

# Copied to a clean location the release step can read.
cp "$notes" "${NOTES_OUT:-/tmp/release-notes.md}"
