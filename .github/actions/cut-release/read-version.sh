#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/cut-release/read-version.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The current version, read from the source the profile names (FR-016). Sourced by the release
# worker's context step and its bump step, so the two cannot read it differently.
#
# Usage: source this file, then `read_version`; it sets `version`, or prints an error and
# returns 1 for a source it does not know. Environment: VERSION_SOURCE (`package-manifest`,
# `git-tag`, `python-project` or `none`). Run from the repository root.
#
# Every first release happens in a repository with no tag, no manifest version or no
# pyproject.toml, so each read falls back to 0.0.0 rather than failing under `set -e`:
# `git describe --tags` exits 128 with no tags (canary run 35383320082).

# shellcheck shell=bash

read_version() {
  case "$VERSION_SOURCE" in
    package-manifest) version=$(jq -r '.version // "0.0.0"' package.json 2>/dev/null || echo "0.0.0") ;;
    git-tag) version=$(git describe --tags --abbrev=0 2>/dev/null || echo ""); version=${version#v}; version=${version:-0.0.0} ;;
    python-project) version=$(sed -n 's/^version *= *"\(.*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 || echo ""); version=${version:-0.0.0} ;;
    none) version="0.0.0" ;;
    *) echo "::error::Unknown version source: $VERSION_SOURCE"; return 1 ;;
  esac
}
