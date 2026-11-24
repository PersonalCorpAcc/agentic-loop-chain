#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/check-implement-eligibility/list-blockers.sh. Profile digest: 971155b21f32. Update with `workflows update --force`; consumer edits may be overwritten.
#
# The issues an issue body names as its blockers, one number per line, each once (FR-147).
#
# Refine writes `Blocked by #M` when order matters (feature 007 X12), but a model does not always
# write it the same way: loopscope #293 said `**Blocked by:** #289, #290, #291, #292`, and the
# pattern every reader used (`blocked by #N`) saw no blocker at all, so implement ran on work
# whose blocker was still open (24/11/2026). Accepted: any case, markdown emphasis and a colon
# after "Blocked by", and a list joined by commas, "and" or "&". One parser, so the eligibility
# check, the held-for-blockers sweep and the orphan restart cannot disagree.
#
# Reads the body on stdin.

set -euo pipefail

grep -oiE 'blocked by[*_: ]*#[0-9]+([*_ ]*(,|and|&)[*_ ]*#[0-9]+)*' | grep -oE '#[0-9]+' | tr -d '#' | sort -un || true
