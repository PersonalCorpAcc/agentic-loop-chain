#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/cut-release/prepare-release-context.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# What the release agent reads before it writes the notes: the commits since the last tag (or
# the last fifty, before the first) and the current version, under AGENT_DIR.
#
# Environment: VERSION_SOURCE, AGENT_DIR (default /tmp/gh-aw/agent). Run from the repository
# root, with its tags fetched.

set -euo pipefail

# shellcheck source=SCRIPTDIR/read-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/read-version.sh"

agent_dir="${AGENT_DIR:-/tmp/gh-aw/agent}"
mkdir -p "$agent_dir"

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$last_tag" ]; then
  git log --oneline --no-decorate "${last_tag}..HEAD" > "$agent_dir/git-log.txt"
else
  git log --oneline --no-decorate -50 > "$agent_dir/git-log.txt"
fi

read_version
echo "$version" > "$agent_dir/current-version.txt"

echo "Last tag: ${last_tag:-none}"
echo "Current version: $version"
