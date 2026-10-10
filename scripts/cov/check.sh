#!/bin/bash
set -euo pipefail

# CI gate: check coverage thresholds.
# Usage: check.sh <tracefile> [--threshold N] [--fail-under N]
#
# --threshold N    Minimum line coverage percentage (default: 0)
# --fail-under N   Alias for --threshold

TRACEFILE=""
THRESHOLD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold|--fail-under)
            THRESHOLD="$2"
            shift 2
            ;;
        *)
            TRACEFILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$TRACEFILE" ]]; then
    echo "Usage: check.sh <tracefile> [--threshold N]" >&2
    exit 1
fi

if [[ ! -f "$TRACEFILE" ]]; then
    echo "FAIL: tracefile not found: $TRACEFILE" >&2
    exit 1
fi

total_lf=0
total_lh=0

while IFS= read -r line; do
    case "$line" in
        LF:*) total_lf=$((total_lf + ${line#LF:})) ;;
        LH:*) total_lh=$((total_lh + ${line#LH:})) ;;
    esac
done < "$TRACEFILE"

if [[ $total_lf -eq 0 ]]; then
    echo "FAIL: no coverage data found" >&2
    exit 1
fi

pct=$(awk "BEGIN { printf \"%.1f\", ($total_lh / $total_lf) * 100 }")
pct_int=$(awk "BEGIN { printf \"%d\", ($total_lh / $total_lf) * 100 }")

echo "Coverage: ${pct}% (${total_lh}/${total_lf}), threshold: ${THRESHOLD}%"

if [[ $pct_int -lt $THRESHOLD ]]; then
    echo "FAIL: coverage ${pct}% is below threshold ${THRESHOLD}%"
    exit 1
fi

echo "PASS"
