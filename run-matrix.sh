#!/usr/bin/env bash
# Runs the evidence matrix and captures one proof log per cell into logs/.
# Full output (including the complete #16008/#16000 signature) is preserved.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/logs"

CELLS=(
  "arm64 pypi root entrypoint"
  "arm64 main root entrypoint"
  "arm64 pypi irisowner entrypoint"
  "arm64 pypi root cistart"
  "amd64 pypi root entrypoint"
  "amd64 main root cistart"
)

summary=()
for cell in "${CELLS[@]}"; do
  # shellcheck disable=SC2086
  set -- $cell
  log="$HERE/logs/$1-$2-$3-$4.log"
  echo "════ cell: $cell → $(basename "$log")"
  bash "$HERE/repro.sh" "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  case "$rc" in
    0) verdict="REPRODUCED" ;;
    2) verdict="not reproduced" ;;
    *) verdict="INFRA FAILURE (rc=$rc)" ;;
  esac
  summary+=("$cell → $verdict")
done

echo
echo "════ MATRIX SUMMARY ($(uname -s) $(uname -m), $(date -u +%Y-%m-%dT%H:%MZ)) ════"
printf '%s\n' "${summary[@]}" | tee "$HERE/logs/SUMMARY.txt"
