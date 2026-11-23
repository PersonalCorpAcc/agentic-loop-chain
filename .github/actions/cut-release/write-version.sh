#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/cut-release/write-version.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Write NEW_VERSION back to the source it was read from, and stage it for the release commit.
# A tag-versioned repository writes nothing: the tag the next step pushes is the version.
#
# Environment: VERSION_SOURCE, NEW_VERSION. Run from the repository root.

set -euo pipefail

case "$VERSION_SOURCE" in
  package-manifest)
    for file in package.json cli/package.json; do
      [ -f "$file" ] || continue
      jq --arg v "$NEW_VERSION" '.version = $v' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      git add "$file"
      echo "Bumped $file to $NEW_VERSION"
    done
    ;;
  python-project)
    sed -i "s/^version *= *\".*\"/version = \"$NEW_VERSION\"/" pyproject.toml
    git add pyproject.toml
    echo "Bumped pyproject.toml to $NEW_VERSION"
    ;;
  git-tag)
    echo "The tag is the version source; nothing to write."
    ;;
esac
