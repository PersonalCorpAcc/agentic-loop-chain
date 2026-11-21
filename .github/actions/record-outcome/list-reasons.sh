#!/usr/bin/env bash
# Every outcome reason written anywhere in the installed actions and workflows, one per line,
# sorted and unique. The route matrix and the package's own test both read this list and check it
# against REASONS in record-outcome.sh, so the two checks cannot drift apart again (feature 007
# QA-12: the test read only `reason:` inputs and the matrix only shell literals).
#
# Usage: list-reasons.sh [actions directory] [workflows directory]
# Defaults are this file's neighbours, which is the layout in both the package and a consumer.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIONS="${1:-${HERE}/..}"
WORKFLOWS="${2:-${HERE}/../../workflows}"

shopt -s nullglob
shell_files=("${ACTIONS}"/*/*.sh)
yaml_files=("${ACTIONS}"/*/*.yml "${WORKFLOWS}"/*.yml "${WORKFLOWS}"/*.md)

{
  # `reason=<code>` in an outcome line, wherever it is written. The matrix and this file are
  # excluded by name: they name codes in their own prose.
  if [ "${#shell_files[@]}" -gt 0 ] || [ "${#yaml_files[@]}" -gt 0 ]; then
    grep -hoE --exclude='verify-route-matrix.sh' --exclude='list-reasons.sh' 'reason=[a-z][a-z-]*' \
      "${shell_files[@]}" "${yaml_files[@]}" 2>/dev/null | sed 's/^reason=//' || true
  fi
  # A shell file assigns its reason to a variable, or hands it to a helper, and writes it later.
  if [ "${#shell_files[@]}" -gt 0 ]; then
    grep -hoE --exclude='verify-route-matrix.sh' --exclude='list-reasons.sh' 'reason="[a-z][a-z-]*"|skipped_because "[a-z][a-z-]*"' \
      "${shell_files[@]}" 2>/dev/null | sed -e 's/^skipped_because //' -e 's/^reason=//' -e 's/"//g' || true
  fi
  # A workflow step hands its reason to record-outcome as an input: `reason: <code>`.
  if [ "${#yaml_files[@]}" -gt 0 ]; then
    grep -hoE '^[[:space:]]+reason: [a-z][a-z-]+[[:space:]]*$' "${yaml_files[@]}" 2>/dev/null |
      sed -E 's/^[[:space:]]+reason: //; s/[[:space:]]+$//' || true
  fi
} | tr -d '\r' | sort -u
