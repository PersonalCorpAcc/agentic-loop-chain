#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/normalise-split-output/normalise-split-output.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# Make a refine split's safe outputs safe to apply, before gh-aw's handlers read them
# (FR-114). Runs as a post-step of refine's agent job: after gh-aw has ingested the agent's
# output into agent_output.json, before that file is uploaded for the safe_outputs job.
#
# Two failures, both seen on loopscope #265 (22/11/2026):
#
# 1. A temporary ID gh-aw rejects. The agent named its children aw_c1 to aw_c6; gh-aw wants
#    `aw_` and 3 to 8 letters or digits, so it gave child 1 an ID of its own and then could
#    not resolve `blocked_by: aw_c1` on children 2 to 6. safe_outputs failed with one orphan
#    child filed and five lost. Every ID gh-aw would reject is renamed here, consistently in
#    `temporary_id`, `blocked_by`, `parent` and `#id` references in any text, so one bad
#    choice of name cannot drop the split.
# 2. A retry of a split that half-succeeded. The children already filed carry the parent's
#    split marker; a `create_issue` whose title matches one of them is dropped, and every
#    reference to its temporary ID points at the existing issue instead, so the retry
#    completes the split rather than filing a second copy.
#
# Reads: REPO, GH_TOKEN, PARENT (the issue being refined), SPLIT_PARENT_PREFIX;
#        AGENT_OUTPUT (default /tmp/gh-aw/agent_output.json); EXISTING_CHILDREN (JSON, tests).
set -euo pipefail

out="${AGENT_OUTPUT:-/tmp/gh-aw/agent_output.json}"
[ -s "$out" ] || exit 0
jq -e '[.items[]? | select(.type == "create_issue")] | length > 0' "$out" >/dev/null 2>&1 || exit 0

marker="${SPLIT_PARENT_PREFIX}${PARENT} -->"
existing="${EXISTING_CHILDREN:-}"
if [ -z "$existing" ]; then
  existing="$(gh issue list --repo "$REPO" --state open --limit 100 --search "\"${SPLIT_PARENT_PREFIX#<!-- }${PARENT}\" in:body" \
    --json number,title,body 2>/dev/null |
    MARKER="$marker" jq -c '[.[] | select((.body // "") | contains(env.MARKER)) | {number, title}]' 2>/dev/null || echo '[]')"
fi

tmp="$(mktemp)"
jq --argjson existing "$existing" '
  def valid: type == "string" and test("^aw_[A-Za-z0-9]{3,8}$");
  def plain: type == "string" and test("^[A-Za-z0-9_-]+$");
  def existing_for($title): [$existing[] | select(.title == $title) | .number][0];

  (.items // []) as $items
  # Children that already exist: their temporary IDs now mean those issues.
  | (reduce ($items[] | select(.type == "create_issue" and (existing_for(.title // "") != null))) as $d
      ({}; if ($d.temporary_id | plain) then . + {($d.temporary_id): existing_for($d.title)} else . end)) as $reuse
  | .items = [$items[] | select((.type == "create_issue" and (existing_for(.title // "") != null)) | not)]
  # Said beside the items, which gh-aw reads, so the refine validator still counts them among
  # the children of this split: a retry that reuses five of six is a split, not one lone child.
  | .reused_children = ((.reused_children // []) + [$reuse[]] | unique)
  # IDs gh-aw would reject, renamed in order of first use.
  | ([.items[] | .temporary_id? | select(type == "string")] | unique) as $ids
  | ([.items[] | .temporary_id? | select(type == "string" and (valid | not) and plain)] | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)) as $bad
  | (reduce range(0; $bad | length) as $i ({};
      . + {($bad[$i]): ([range(1; 100) | "aw_split\(.)" | select(. as $c | $ids | index([$c]) | not)][$i])})) as $rename
  | walk(
      if type == "string" then
        if $rename[.] != null then $rename[.]
        elif $reuse[.] != null then $reuse[.]
        else
          reduce ($rename | to_entries[]) as $e (.; gsub("#\($e.key)(?![A-Za-z0-9_])"; "#\($e.value)"))
          | reduce ($reuse | to_entries[]) as $e (.; gsub("#\($e.key)(?![A-Za-z0-9_])"; "#\($e.value)"))
        end
      else . end)
' "$out" > "$tmp"

renamed="$(jq -r --slurpfile before "$out" '[$before[0].items[]? | .temporary_id? | select(type == "string")] - [.items[]? | .temporary_id? | select(type == "string")] | join(", ")' "$tmp")"
mv "$tmp" "$out"
[ -z "$renamed" ] || echo "Split output: rewrote or reused temporary IDs ${renamed}."
echo "Split output normalised: $(jq '[.items[] | select(.type == "create_issue")] | length' "$out") child issue(s) to create."
