#!/bin/bash
set -euo pipefail

# Merge multiple lcov tracefiles into one.
# Usage: merge.sh -o <output> <input1> [input2 ...]

OUTPUT=""
INPUTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        *)
            INPUTS+=("$1")
            shift
            ;;
    esac
done

if [[ -z "$OUTPUT" ]] || [[ ${#INPUTS[@]} -eq 0 ]]; then
    echo "Usage: merge.sh -o <output> <input1> [input2 ...]" >&2
    exit 1
fi

if ! command -v lcov &>/dev/null; then
    echo "Error: lcov not found. Install with: apt-get install lcov / brew install lcov" >&2
    exit 1
fi

LCOV_ARGS=()
for f in "${INPUTS[@]}"; do
    if [[ -f "$f" ]] && [[ -s "$f" ]]; then
        LCOV_ARGS+=("-a" "$f")
    fi
done

if [[ ${#LCOV_ARGS[@]} -eq 0 ]]; then
    echo "Error: no non-empty input files found" >&2
    exit 1
fi

lcov "${LCOV_ARGS[@]}" -o "$OUTPUT" --quiet
echo "Merged ${#INPUTS[@]} files -> $OUTPUT"
