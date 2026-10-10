#!/bin/bash
set -euo pipefail

# Generate HTML report from lcov tracefile.
# Usage: html.sh <tracefile> [output_dir]

TRACEFILE="${1:?Usage: html.sh <tracefile> [output_dir]}"
OUTPUT_DIR="${2:-./coverage/html}"

if ! command -v genhtml &>/dev/null; then
    echo "Error: genhtml not found. Install with: apt-get install lcov / brew install lcov" >&2
    exit 1
fi

if [[ ! -f "$TRACEFILE" ]]; then
    echo "Error: tracefile not found: $TRACEFILE" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
genhtml "$TRACEFILE" --output-directory "$OUTPUT_DIR" --quiet \
    --title "skytest" \
    --legend \
    --branch-coverage 2>/dev/null || \
genhtml "$TRACEFILE" --output-directory "$OUTPUT_DIR" --quiet \
    --title "skytest" \
    --legend

echo "HTML report: $OUTPUT_DIR/index.html"
