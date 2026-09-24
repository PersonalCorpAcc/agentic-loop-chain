#!/usr/bin/env bash
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/actions/guard-branch-write/guard-branch-write.sh. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
#
# May this job write this branch? (FR-063)
#
# Every deterministic job that pushes takes its branch name from something it did not
# write: an agent's JSON output, a pull request body, an event payload. None of those is
# trusted. The rule is an allow-list shaped as a deny-list: the branch must match the
# template this loop names its branches with, and must not be a branch the loop promotes
# into, cuts from, releases, or the repository's own default.
#
# Refusal is loud and names the branch and the reason, because the alternative -- a job
# that quietly writes `main` because a JSON field said so -- is the failure this exists to
# prevent.
#
# Usage: BRANCH=<branch> guard-branch-write.sh
# Environment: BRANCH, DENIED_BRANCHES (newline or comma separated), RELEASE_PATTERN,
#              BRANCH_PATTERN, DEFAULT_BRANCH.
#
# The branch arrives in the environment rather than as an argument on purpose. A value
# carrying a newline does not survive process arguments on every platform -- one runtime
# delivered only the first line, so a name built to smuggle a second one read as a valid
# name -- and the environment carries it verbatim everywhere.

set -euo pipefail

BRANCH="${BRANCH:-}"

fail() {
  echo "::error::refusing to write branch '${BRANCH}': $1"
  exit 1
}

[ -n "$BRANCH" ] || fail "no branch was supplied"

# A name beginning with a hyphen is read as an option by every git command downstream, and
# `git check-ref-format` cannot be asked about it: it takes no `--` separator and answers a
# usage error, which would read as "invalid" for every name alike. So it is refused here, by
# hand, before git sees it -- the same rule `profile-schema.ts` applies to a profile's
# branch fields. Every git command that does take `--` is given it at the call site.
case "$BRANCH" in
  -*) fail "it begins with a hyphen, which every git command downstream would read as an option" ;;
esac

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || fail "it is not a valid branch name"

# The characters a branch this loop writes may contain, as an allow-list. Two reasons, and
# the second is the one that bites: a name is interpolated into shell and into git
# arguments downstream, and every check below this line is `grep`, which matches one line
# at a time -- so a name carrying a newline passes the template check on its first line and
# brings a second line with it. git itself permits more than this; a branch made from a
# template and an issue number does not need it.
case "$BRANCH" in
  *[!A-Za-z0-9._/-]*) fail "it contains a character no branch this loop writes contains" ;;
esac

if [ -n "${DEFAULT_BRANCH:-}" ] && [ "$BRANCH" = "$DEFAULT_BRANCH" ]; then
  fail "it is the repository's default branch"
fi

# The stages a change is promoted into, and the branch it is cut from. A deterministic job
# may open a pull request against one of these; it may never push one.
while IFS= read -r denied; do
  [ -n "$denied" ] || continue
  if [ "$BRANCH" = "$denied" ]; then
    fail "it is a branch this loop promotes into or cuts from"
  fi
done < <(printf '%s\n' "${DENIED_BRANCHES:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -n "${RELEASE_PATTERN:-}" ] && printf '%s' "$BRANCH" | grep -qE "${RELEASE_PATTERN}"; then
  fail "it matches the release branch pattern '${RELEASE_PATTERN}'"
fi

# The last rule is the one that makes the others a belt rather than the whole answer: a
# branch this loop did not name is a branch this loop does not write, whatever it is called.
if [ -n "${BRANCH_PATTERN:-}" ] && ! printf '%s' "$BRANCH" | grep -qE "${BRANCH_PATTERN}"; then
  fail "it does not match the branch template this loop writes ('${BRANCH_PATTERN}')"
fi

echo "Branch '${BRANCH}' may be written by this job."
