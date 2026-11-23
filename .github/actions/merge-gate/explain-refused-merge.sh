#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/explain-refused-merge.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The gate approved a pull request the forge would not merge or queue: say why on it.
#
# Environment: GH_TOKEN, REPO, PR, REFUSAL, ARMED, ARM_ERROR, DEFERRABLE.

set -euo pipefail
if [ "$DEFERRABLE" = "true" ] && [ "$ARMED" != "true" ]; then
  gh pr comment "$PR" --repo "$REPO" --body "The merge gate approved this pull request but could not merge or queue it: ${REFUSAL}

  It could not be marked ready either. The forge said:

  > ${ARM_ERROR:-no reason given}

  Two things cause that. **Allow auto-merge** may be switched off for this repository, which is its default. Or the merge method this loop is configured for may not be one the repository or its rulesets permit, in which case the two settings disagree and one of them has to move. Either way this pull request waits for a person."
else
  gh pr comment "$PR" --repo "$REPO" --body "The merge gate approved this pull request but did not merge it: ${REFUSAL}"
fi
