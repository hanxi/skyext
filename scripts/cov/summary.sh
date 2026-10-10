#!/bin/bash
set -euo pipefail

# Print coverage summary from lcov tracefile.
# Usage: summary.sh <tracefile>

TRACEFILE="${1:?Usage: summary.sh <tracefile>}"

if [[ ! -f "$TRACEFILE" ]]; then
    echo "Error: tracefile not found: $TRACEFILE" >&2
    exit 1
fi

total_lf=0
total_lh=0
file_count=0
declare -A file_lf file_lh 2>/dev/null || true

current_sf=""
while IFS= read -r line; do
    case "$line" in
        SF:*)
            current_sf="${line#SF:}"
            file_count=$((file_count + 1))
            ;;
        LF:*)
            lf="${line#LF:}"
            total_lf=$((total_lf + lf))
            ;;
        LH:*)
            lh="${line#LH:}"
            total_lh=$((total_lh + lh))
            ;;
    esac
done < "$TRACEFILE"

if [[ $total_lf -eq 0 ]]; then
    echo "No coverage data found."
    exit 0
fi

pct=$(awk "BEGIN { printf \"%.1f\", ($total_lh / $total_lf) * 100 }")
uncovered=$((total_lf - total_lh))

echo "=================================="
echo "  skytest Coverage Summary"
echo "=================================="
echo "  Files:     $file_count"
echo "  Lines:     $total_lf"
echo "  Covered:   $total_lh"
echo "  Uncovered: $uncovered"
echo "  Coverage:  ${pct}%"
echo "=================================="
