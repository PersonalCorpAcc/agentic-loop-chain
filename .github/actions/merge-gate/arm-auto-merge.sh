#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/merge-gate/arm-auto-merge.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# A rule is holding the pull request, and a rule can still be satisfied (FR-080): mark it
# ready, so the forge merges it when the required review or check arrives.
#
# Environment: GH_TOKEN, REPO, PR, MERGE_METHOD, REFUSAL (the forge's reason).
# Outputs: armed, arm_error (when it could not be armed).

set -euo pipefail
# The method is the profile's, chosen here rather than at merge time because with
# auto-merge the forge performs the merge later and takes the method now.
if armed="$(gh pr merge "$PR" --repo "$REPO" "--${MERGE_METHOD}" --auto 2>&1)"; then
  echo "armed=true" >> "$GITHUB_OUTPUT"
  gh pr comment "$PR" --repo "$REPO" --body "The merge gate found nothing to stop this pull request and has marked it ready: ${REFUSAL}

  Nothing else is needed from the loop. Nothing about the issue has changed -- it is still reserved and still pending."
  echo "PR #${PR}: auto-merge armed (${MERGE_METHOD}); waiting for the rule to be satisfied."
else
  # The forge's own sentence, carried rather than guessed. There are at least two
  # causes and they want different remedies: `Auto merge is not allowed for this
  # repository` is the setting, off by default, and `Merge method rebase merging is
  # not allowed` is the profile's merge method against what the repository or a
  # ruleset permits -- observed 18/09/2026. Both refuse at once rather than
  # accepting and never completing, which is the good outcome; what would make it
  # expensive is a message that sent the reader to the wrong switch.
  echo "armed=false" >> "$GITHUB_OUTPUT"
  {
    echo 'arm_error<<GHAWEOF'
    printf '%s\n' "$armed" | head -n 3
    echo GHAWEOF
  } >> "$GITHUB_OUTPUT"
  echo "::warning::PR #${PR}: auto-merge could not be armed. ${armed}"
fi
