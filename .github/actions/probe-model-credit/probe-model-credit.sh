#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/probe-model-credit/probe-model-credit.sh. Profile digest: ebdd90dc5c5b. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Will the account behind the model credential pay for a run? Spends one token to ask
# (FR-087): a key with no credit answers every read-only endpoint happily and refuses only at
# inference.
#
# Exits 1 when the credential is empty or the provider answers with its refusal; exits 0 when
# it answers otherwise, and when no probe is characterised for the engine, which is unknown
# rather than a failure.
#
# Environment: CREDENTIAL, PROBE (the engine table's probe name, may be empty), MODEL,
# REFUSAL_SIGNATURE (an extended expression for the provider's refusal).

set -uo pipefail

if [ -z "${PROBE:-}" ]; then
  echo "::notice::No credit probe is characterised for this repository's engine, so whether the account will pay is unknown until an agent runs. The engine table names a probe only for the shapes this project has watched succeed and fail."
  exit 0
fi
if [ -z "${CREDENTIAL:-}" ]; then
  echo "::error::The model credential secret is empty, so no agent can run at all."
  exit 1
fi

case "$PROBE" in
  anthropic-messages)
    answer="$(curl --silent --show-error --max-time 30 \
      -H "x-api-key: ${CREDENTIAL}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "{\"model\":\"${MODEL}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\".\"}]}" \
      https://api.anthropic.com/v1/messages 2>&1)"
    ;;
  *)
    echo "::warning::${PROBE} is named as this engine's credit probe and this router does not implement it; treating the account as unknown."
    exit 0
    ;;
esac

# The status is not the answer: a refusal is a 400 like several other things, and the
# provider's own words are what the implement worker stops on too.
if printf '%s' "$answer" | grep -qiE "${REFUSAL_SIGNATURE}"; then
  echo "::error::The account behind this repository's model credential will not pay: the provider answered with its refusal. Nothing else here is wrong, and no agent can run until it is topped up."
  exit 1
fi
echo "::notice::The model credential answered, so the account will pay for a run."
