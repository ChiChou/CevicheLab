#!/bin/bash
# Isolated investigation; creates no export format and adds no encoder dependency.
set -euo pipefail
EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$EXPERIMENT_DIR/../.." && pwd)"
CEVICHE_ROOT="${CEVICHE_ROOT:-$LAB_ROOT/../Ceviche}"
APP_ROOT="$CEVICHE_ROOT/app"
if [[ ! -f "$APP_ROOT/scripts/test.sh" ]]; then
    echo "Set CEVICHE_ROOT to a Ceviche checkout containing app/scripts/test.sh" >&2
    exit 2
fi
if [[ $# -ne 1 ]]; then
    echo "Usage: bash run.sh /absolute/path/to/reference.ARW" >&2
    exit 2
fi
RESEARCH_OUTPUT="$LAB_ROOT/.build/linear-dng-research"
mkdir -p "$RESEARCH_OUTPUT"
CEVICHE_DNG_RESEARCH_RAW="$1" CEVICHE_DNG_RESEARCH_OUTPUT="$RESEARCH_OUTPUT" \
    "$APP_ROOT/scripts/test.sh" --filter LinearDNGInvestigationTests
swiftc -O "$EXPERIMENT_DIR/probe.swift" -o "$RESEARCH_OUTPUT/probe"
"$RESEARCH_OUTPUT/probe" prepare "$RESEARCH_OUTPUT" > "$RESEARCH_OUTPUT/prepare.log"
python3 "$EXPERIMENT_DIR/make_dng.py" "$RESEARCH_OUTPUT"
"$RESEARCH_OUTPUT/probe" decode "$RESEARCH_OUTPUT" > "$RESEARCH_OUTPUT/decode.log"
echo "Research files and metrics: $RESEARCH_OUTPUT"
