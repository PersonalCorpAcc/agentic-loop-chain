#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/decide-auto-merge.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Does a clean assessment of this pull request merge it, or does a person? Answered once,
# beside the base it depends on, for the prompt, the merge step and the outcome line.
# Advice on a person's pull request merges nothing (FR-027).
#
# Environment: BASE, AUTO_MERGE_MODE, AUTO_MERGE_TARGETS (comma-separated), ADVISE.
# Outputs: auto_merge, verdict_word, verdict_sentence.

set -euo pipefail
# Advice merges nothing, whatever the policy says about this base (FR-027).
if [ "${ADVISE:-false}" = "true" ]; then
  {
    echo "auto_merge=false"
    echo "verdict_word=approve"
    echo "verdict_sentence=this is advice on a person's pull request and nothing merges; say approve"
  } >> "$GITHUB_OUTPUT"
  echo "A person's pull request, assessed advise-only: nothing merges whatever the verdict."
  exit 0
fi
auto_merge=false
if [ "${AUTO_MERGE_MODE:-off}" != "off" ] && [ -n "${BASE:-}" ]; then
  while IFS= read -r target; do
    [ "$target" = "$BASE" ] || continue
    auto_merge=true
    break
  done < <(printf '%s\n' "${AUTO_MERGE_TARGETS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
fi
echo "auto_merge=$auto_merge" >> "$GITHUB_OUTPUT"
if [ "$auto_merge" = true ]; then
  echo "verdict_word=merge" >> "$GITHUB_OUTPUT"
  echo "verdict_sentence=this pull request merges itself when you say merge" >> "$GITHUB_OUTPUT"
  echo "This repository merges into ${BASE} unattended (${AUTO_MERGE_MODE}); a clean assessment merges."
else
  echo "verdict_word=approve" >> "$GITHUB_OUTPUT"
  echo "verdict_sentence=a person merges this pull request; say approve" >> "$GITHUB_OUTPUT"
  echo "This repository does not merge into ${BASE:-?} unattended; a clean assessment is an approval and a person merges."
fi
