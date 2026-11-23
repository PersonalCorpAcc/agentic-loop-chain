#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/verify-on-stop/verify-on-stop.sh. Profile digest: ede943dfa18d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The agent session's stop hook (feature 007 X10, FR-026): the session cannot finish while the
# repository's verify command fails.
#
# The prompt already says "verify before you conclude", and a prompt is a request. Under an
# engine with a stop hook (Claude Code's `Stop`), this makes it a check the session runs into:
# exit 2 refuses the stop and hands the agent the failure to fix. It refuses at most
# VERIFY_ON_STOP_LIMIT times (3), then lets the session end -- a session that cannot get its
# verify green should still end with its outcome, and the merge gate checks CI regardless.
#
# Reads the command a pre-agent step wrote to VERIFY_ON_STOP_FILE (default
# /tmp/gh-aw/agent/verify-command). No file, or an empty one, means nothing to check. Several
# projects arrive as `Label: chain | Label: chain` (FR-010) and each chain runs on its own.
set -uo pipefail

command_file="${VERIFY_ON_STOP_FILE:-/tmp/gh-aw/agent/verify-command}"
limit="${VERIFY_ON_STOP_LIMIT:-3}"
[ -s "$command_file" ] || exit 0
verify="$(cat "$command_file")"
[ -n "${verify//[[:space:]]/}" ] || exit 0

count_file="${command_file}.refusals"
refusals="$(cat "$count_file" 2>/dev/null || echo 0)"
if [ "$refusals" -ge "$limit" ]; then
  echo "verify-on-stop: refused ${refusals} times already; letting the session end." >&2
  exit 0
fi

# The labelled form only when every segment carries a label: a single project's chain may
# contain a pipe of its own.
chains=()
if printf '%s' "$verify" | awk -F ' [|] ' '{ for (i = 1; i <= NF; i++) if ($i !~ /^[A-Za-z0-9_.-]+: /) exit 1 }' && [[ "$verify" == *" | "* ]]; then
  while IFS= read -r segment; do chains+=("${segment#*: }"); done < <(printf '%s\n' "$verify" | awk -F ' [|] ' '{ for (i = 1; i <= NF; i++) print $i }')
else
  chains=("$verify")
fi

out="$(mktemp)"
status=0
for chain in "${chains[@]}"; do
  echo "\$ ${chain}" >>"$out"
  bash -c "$chain" >>"$out" 2>&1 || { status=1; break; }
done

if [ "$status" -ne 0 ]; then
  echo $((refusals + 1)) >"$count_file"
  {
    echo "The repository's verify command fails, so this session cannot finish yet. Fix the cause and"
    echo "finish again. Do not weaken a test, lower a threshold or skip a check to make it pass."
    echo "--- last lines of the output ---"
    tail -n 60 "$out"
  } >&2
  rm -f "$out"
  exit 2
fi
rm -f "$out"
exit 0
