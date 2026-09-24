---
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/workflows/agent-release.md. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
env:
  GIT_AUTHOR_NAME: "personalcorpacc-agentic-loop[bot]"
  GIT_AUTHOR_EMAIL: "personalcorpacc-agentic-loop[bot]@users.noreply.github.com"
  GIT_COMMITTER_NAME: "personalcorpacc-agentic-loop[bot]"
  GIT_COMMITTER_EMAIL: "personalcorpacc-agentic-loop[bot]@users.noreply.github.com"
  # Where the current version is read from and, except for git-tag, written to:
  # package-manifest, git-tag, python-project or none. Under none nothing is
  # bumped or tagged and the notes go to the step summary (FR-016).
  VERSION_SOURCE: git-tag
description: |
  Generates release notes from the commit log and creates a tagged GitHub Release.
  The agent writes human-readable release notes; every other step (version bump,
  commit, tag, push, release creation) is deterministic.

  Router-only worker: triggered exclusively via workflow_call from work-router.yml.
  Contract input: version-bump(patch|minor|major|auto).

name: "Agent: Release"

imports:
  - shared/platform-defaults.md
  - shared/stack-node-pnpm.md
on:
  workflow_call:
    inputs:
      version-bump:
        description: "Version bump strategy: patch, minor, major, or auto"
        required: false
        type: string
        default: "auto"

runs-on: ubuntu-24.04
runs-on-slim: ubuntu-24.04

engine:
  id: claude
model: claude-sonnet-5

max-turns: 100
max-turn-cache-misses: 3000
max-ai-credits: 2000

permissions: read-all

checkout:
  fetch: ["*"]
  fetch-depth: 0

steps:
  - name: Prepare release context
    env:
      GH_TOKEN: ${{ github.token }}
      REPO: ${{ github.repository }}
    run: |
      set -euo pipefail
      mkdir -p /tmp/gh-aw/agent

      last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
      if [ -n "$last_tag" ]; then
        git log --oneline --no-decorate "${last_tag}..HEAD" > /tmp/gh-aw/agent/git-log.txt
      else
        git log --oneline --no-decorate -50 > /tmp/gh-aw/agent/git-log.txt
      fi

      case "$VERSION_SOURCE" in
        package-manifest) version=$(jq -r '.version // "0.0.0"' package.json 2>/dev/null || echo "0.0.0") ;;
        git-tag) version=$(git describe --tags --abbrev=0 2>/dev/null || echo ""); version=${version#v}; version=${version:-0.0.0} ;;
        python-project) version=$(sed -n 's/^version *= *"\(.*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 || echo ""); version=${version:-0.0.0} ;;
        none) version="0.0.0" ;;
        *) echo "::error::Unknown version source: $VERSION_SOURCE"; exit 1 ;;
      esac
      echo "$version" > /tmp/gh-aw/agent/current-version.txt

      echo "Last tag: ${last_tag:-none}"
      echo "Current version: $version"

safe-outputs:
  report-failure-as-issue: false
  threat-detection: false
  noop:
    max: 1

timeout-minutes: 30

jobs:
  conclude:
    needs: [activation, agent, safe_outputs]
    if: >
      always() &&
      needs.agent.result == 'success' &&
      needs.safe_outputs.result == 'success'
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - name: Download agent output artifact
        id: download-agent-output
        continue-on-error: true
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          pattern: "{${{ needs.activation.outputs.artifact_prefix }}agent,${{ needs.activation.outputs.artifact_prefix }}agent-output-fallback}"
          merge-multiple: true
          path: /tmp/gh-aw/
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          token: ${{ github.token }}
          fetch-depth: 0
      - name: Read release notes and determine version
        id: release
        env:
          VERSION_BUMP: ${{ inputs.version-bump }}
        run: |
          set -euo pipefail

          notes="/tmp/gh-aw/agent/release-notes.md"
          if [ ! -f "$notes" ]; then
            echo "::error::Agent did not write release-notes.md"
            exit 1
          fi

          case "$VERSION_SOURCE" in
            package-manifest) version=$(jq -r '.version // "0.0.0"' package.json 2>/dev/null || echo "0.0.0") ;;
            git-tag) version=$(git describe --tags --abbrev=0 2>/dev/null || echo ""); version=${version#v}; version=${version:-0.0.0} ;;
            python-project) version=$(sed -n 's/^version *= *"\(.*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 || echo ""); version=${version:-0.0.0} ;;
            none) version="0.0.0" ;;
            *) echo "::error::Unknown version source: $VERSION_SOURCE"; exit 1 ;;
          esac
          current="$version"
          echo "current_version=$current" >> "$GITHUB_OUTPUT"

          # Determine the version bump
          bump="$VERSION_BUMP"
          if [ "$bump" = "auto" ]; then
            if grep -qiE 'BREAKING CHANGE' "$notes" || grep -qE '\w+\(!:' /tmp/gh-aw/agent/git-log.txt; then
              bump="major"
            elif grep -qE '^feat(\(.+\))?:' /tmp/gh-aw/agent/git-log.txt; then
              bump="minor"
            else
              bump="patch"
            fi
          fi

          # Semver bump
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

          # Copy notes to a clean location the release step can read
          cp "$notes" /tmp/release-notes.md
      - name: Write the new version to its source
        if: env.VERSION_SOURCE != 'none'
        env:
          NEW_VERSION: ${{ steps.release.outputs.new_version }}
        run: |
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
      - name: Commit, tag, and push
        if: env.VERSION_SOURCE != 'none'
        env:
          NEW_VERSION: ${{ steps.release.outputs.new_version }}
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          git config user.name "$GIT_AUTHOR_NAME"
          git config user.email "$GIT_AUTHOR_EMAIL"

          # The checkout persists no credentials, so GH_TOKEN reaches `gh` and not git, and
          # the push fails with "could not read Username" after the notes have been written.
          # Carried per command through git's own environment rather than written into the
          # remote URL, which .git/config would keep and every later step would inherit
          # (FR-067).
          host="${GITHUB_SERVER_URL#https://}"
          git remote set-url origin "https://${host}/${GITHUB_REPOSITORY}.git"
          GIT_CONFIG_COUNT=1
          GIT_CONFIG_KEY_0=http.extraheader
          GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
          export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

          if ! git diff --cached --quiet; then
            git commit -m "chore(release): v${NEW_VERSION}"
            # The version commit lands on the default branch, which an adopter's rules may
            # protect against exactly this. A refusal here is the forge working, and it says
            # which rule it was; a repository whose version source is the tag stages nothing
            # and never reaches this line.
            git push
          fi
          git tag "v${NEW_VERSION}"
          git push origin "v${NEW_VERSION}"
          echo "Tagged v${NEW_VERSION} and pushed."
      - name: Create GitHub Release
        if: env.VERSION_SOURCE != 'none'
        env:
          NEW_VERSION: ${{ steps.release.outputs.new_version }}
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          gh release create "v${NEW_VERSION}" \
            --repo "$GITHUB_REPOSITORY" \
            --title "v${NEW_VERSION}" \
            --notes-file /tmp/release-notes.md
          echo "GitHub Release v${NEW_VERSION} created."
      - name: Publish the notes without a release
        # A repository with no version source has nothing to tag, so the notes
        # are the deliverable (FR-016).
        if: env.VERSION_SOURCE == 'none'
        run: |
          set -euo pipefail
          {
            echo "## Release notes"
            echo
            cat /tmp/release-notes.md
          } >> "$GITHUB_STEP_SUMMARY"
          echo "No version source: notes written to the step summary; nothing bumped or tagged."
      - name: Record the outcome
        if: always()
        uses: ./.github/actions/record-outcome
        with:
          outcome: ${{ job.status == 'success' && 'acted' || 'failed' }}
          reason: ${{ job.status == 'success' && 'acted' || 'invalid-input' }}
          route: release
          subject: '-'
          detail: "${{ job.status == 'success' && 'The release ran; the run log names the version it cut.' || 'The release conclusion did not finish; the step log says where it stopped.' }}"

  incomplete:
    needs: [agent, safe_outputs]
    if: >
      always() &&
      (needs.agent.result != 'success' || needs.safe_outputs.result != 'success')
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - name: Report release failure
        run: |
          echo "::error::Release agent did not complete successfully."
          echo "The release was not created. Check the agent logs."
          exit 1

---

1. Read `/tmp/gh-aw/agent/git-log.txt`. It contains the commit log since the last
   tag (or the last 50 commits if no tag exists).

2. Read `/tmp/gh-aw/agent/current-version.txt` for the current version.

3. Categorize commits by conventional-commit prefix:
   - `feat:` / `feat(scope):` → Features
   - `fix:` / `fix(scope):` → Bug Fixes
   - `chore:` / `chore(scope):` → Maintenance
   - `docs:` → Documentation
   - `refactor:` → Refactoring
   - `perf:` → Performance
   - Any `BREAKING CHANGE` footer or `!:` prefix → Breaking Changes (top of the notes)

4. Write structured release notes in markdown to `/tmp/gh-aw/agent/release-notes.md`.
   Format:
   - A `## What's Changed` heading
   - Breaking Changes section first (if any)
   - Grouped sections: `### Features`, `### Bug Fixes`, etc.
   - One bullet per commit with the commit message (not the hash)
   - A `**Full Changelog**: <last-tag>...<new-tag>` line at the end
   - Keep it concise and factual. Do not invent changes that are not in the log.

5. Call `noop` and stop. The deterministic `conclude` job reads the notes you wrote
   and handles version bumping, tagging, and release creation.

## Diagram

```mermaid
flowchart TD
    relStart("Work Router<br/>release route<br/>(manual dispatch)") --> relActivation
    relActivation("Activation<br/>Prepare prompt + env") --> relPreAgent
    relPreAgent["Pre-agent<br/>Write git log + version to /tmp"] --> relAgent
    relAgent["Agent<br/>Read commit log<br/>Write release-notes.md"] --> relNoop
    relNoop("Safe Outputs<br/>Process noop") --> relConclude
    relConclude["Conclude<br/>Bump version, commit, tag<br/>push, create GitHub Release"]
    relConclude --> relDone(("Released<br/>Tag + GitHub Release created"))
    relConclude -.->|failure| relFail(("Failed<br/>No tag created"))
    classDef start fill:#ffffff,stroke:#172033,stroke-width:2px,color:#172033
    classDef action fill:#eef0ff,stroke:#554cff,stroke-width:2px,color:#172033
    classDef success fill:#e8f8ec,stroke:#18883c,stroke-width:2px,color:#145a32
    classDef failure fill:#fff0f0,stroke:#ef2929,stroke-width:2px,color:#8b1a2a
    class relStart start
    class relActivation,relPreAgent,relAgent action
    class relDone success
    class relFail failure
```
