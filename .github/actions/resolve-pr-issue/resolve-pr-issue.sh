#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/resolve-pr-issue/resolve-pr-issue.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Which issue does this pull request belong to? (FR-030)
#
# The forge answers that question from a closing keyword in the body, and this loop no
# longer writes one: a keyword closes the issue at the first merge into the default branch,
# and under a chain the first merge is the first of three stages. So the link is a marker
# the App stamps, `<!-- implement-issue: N -->`, and the forge's own answer is a fallback
# for a pull request a person opened the ordinary way.
#
# One file, sourced by everything that asks. Eight places asked before this existed, each
# with its own spelling of the same query, and the day the keyword stopped being written
# every one of them would have started answering "no issue" -- separately, quietly, and in
# a different way each time.
#
# Usage: source this file, then `pr_issue <number>`; it prints the issue number or nothing.
# `pr_issues <number>` prints every issue the pull request belongs to, one per line, which
# under `env-promotion` is the set a single promotion carries (FR-031, FR-056).
# Environment: GH_TOKEN, and REPO or GITHUB_REPOSITORY.

# shellcheck shell=bash

# Every issue this pull request belongs to, one per line, oldest marker first and each one
# once.
#
# One pull request, several issues, is what `env-promotion` promotes: the head is a snapshot
# of the stage below, so the changes it carries are whatever merged there since the last
# promotion, and the route stamps one `implement-issue` marker per carried issue. Every other
# strategy carries exactly one, and for them this prints the same answer `pr_issue` does --
# which is why the single reader stays and is written in terms of this one, rather than two
# spellings of the marker grammar drifting apart (FR-030, FR-031).
pr_issues() {
  local pr="$1"
  local repo="${REPO:-${GITHUB_REPOSITORY:-}}"
  local pr_json body markers

  [ -n "$pr" ] || return 0
  [ -n "$repo" ] || return 0
  case "$pr" in
    '' | *[!0-9]*) return 0 ;;
  esac

  pr_json="$(gh pr view "$pr" --repo "$repo" --json body,closingIssuesReferences 2>/dev/null || true)"
  [ -n "$pr_json" ] || return 0

  body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
  # `awk '!seen[$0]++'` rather than `sort -u`: the order markers were written in is the
  # order the changes were carried in, and a set that reorders them would report the
  # promotion's contents in an order nobody can check against the log.
  markers="$(printf '%s' "$body" |
    grep -oE '<!-- implement-issue: [0-9]+ -->' |
    grep -oE '[0-9]+' | awk '!seen[$0]++' || true)"
  if [ -n "$markers" ]; then
    printf '%s\n' "$markers"
    return 0
  fi

  # No marker at all: fall back to the single-issue rule, so a person's pull request and a
  # pre-marker one answer here exactly as they do everywhere else.
  local single
  single="$(pr_issue "$pr")"
  [ -z "$single" ] || printf '%s\n' "$single"
}

pr_issue() {
  local pr="$1"
  local repo="${REPO:-${GITHUB_REPOSITORY:-}}"
  local pr_json body issue

  [ -n "$pr" ] || return 0
  [ -n "$repo" ] || return 0
  case "$pr" in
    '' | *[!0-9]*) return 0 ;;
  esac

  pr_json="$(gh pr view "$pr" --repo "$repo" --json body,closingIssuesReferences 2>/dev/null || true)"
  [ -n "$pr_json" ] || return 0

  # The marker first. It is written by the App after the pull request exists, because the
  # framework strips every HTML comment from what the agent produces.
  body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
  issue="$(printf '%s' "$body" | grep -oE '<!-- implement-issue: [0-9]+ -->' | grep -oE '[0-9]+' | head -n1 || true)"
  if [ -n "$issue" ]; then
    printf '%s' "$issue"
    return 0
  fi

  # Then the forge's own link, which a person's pull request still carries.
  issue="$(printf '%s' "$pr_json" | jq -r '.closingIssuesReferences[0].number // empty')"
  if [ -n "$issue" ]; then
    printf '%s' "$issue"
    return 0
  fi

  # Then a keyword in the body that the forge has not turned into a link yet, and a bare
  # `Refs #12`, which is what this loop leaves behind when it neutralises one.
  printf '%s' "$body" |
    grep -oiE '(close[sd]?|fixe?[sd]?|resolve[sd]?|refs?)[[:space:]:]*#[0-9]+' |
    grep -oE '[0-9]+' | head -n1 || true
}
