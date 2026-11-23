#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/runner-preflight/runner-preflight.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Is there an online runner for every self-hosted tier the profile names? (FR-070, FR-058)
#
# A tier whose labels are all GitHub-hosted names has nothing to check. Organisation runners
# shared to this repository are not in the repository's runner list, so the organisation's is
# tried next, and an endpoint the token may not read makes the answer unverifiable rather than
# "offline": exit 0 with reason runner-unverifiable. An offline tier exits 1, in red, with
# reason runner-offline.
#
# Environment: GH_TOKEN, REPO, OWNER, TIER_AGENT, TIER_SLIM, TIER_CI (comma-separated labels,
# any may be empty), GITHUB_STEP_SUMMARY.

set -euo pipefail

summary() { echo "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; echo "$1"; }
hosted='^(ubuntu|windows|macos)-'
runners=""
source=""
for endpoint in "repos/$REPO/actions/runners" "orgs/$OWNER/actions/runners"; do
  if out="$(gh api --paginate "$endpoint" --jq '.runners[] | select(.status == "online") | [.labels[].name] | join(",")' 2>/dev/null)"; then
    source="$endpoint"
    runners="$out"
    [ -n "$runners" ] && break
  fi
done
offline=""
for tier in "agent=${TIER_AGENT:-}" "slim=${TIER_SLIM:-}" "ci=${TIER_CI:-}"; do
  name="${tier%%=*}"; labels="${tier#*=}"
  [ -n "$labels" ] || continue
  self_hosted=false
  for label in ${labels//,/ }; do
    printf '%s' "$label" | grep -Eq "$hosted" || self_hosted=true
  done
  [ "$self_hosted" = true ] || continue
  if [ -z "$source" ]; then
    summary "outcome=no-action route=- subject=- reason=runner-unverifiable"
    summary "Neither the repository's nor the organisation's runner list could be read with this token, so whether the $name tier is online is not known."
    exit 0
  fi
  found=false
  while IFS= read -r have; do
    [ -n "$have" ] || continue
    ok=true
    for label in ${labels//,/ }; do
      case ",$have," in *",$label,"*) ;; *) ok=false ;; esac
    done
    [ "$ok" = true ] && found=true
  done <<<"$runners"
  [ "$found" = true ] || offline="$offline $name($labels)"
done
if [ -n "$offline" ]; then
  summary "outcome=failed route=- subject=- reason=runner-offline"
  summary "No online runner carries every label of:$offline. Work routed to those tiers would queue with no runner to take it."
  exit 1
fi
summary "outcome=no-action route=- subject=- reason=runners-online"
summary "Every self-hosted tier has an online runner."
