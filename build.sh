#!/usr/bin/env bash
# Build gokz-replays.smx using the vendored SourceMod 1.11 compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPCOMP="$ROOT/tools/sourcemod/spcomp64"
OUT_DIR="${OUT_DIR:-$ROOT/build}"

if [[ ! -x "$SPCOMP" ]]; then
	echo "spcomp64 not found at: $SPCOMP" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
"$SPCOMP" "$ROOT/gokz-replays.sp" \
	-i "$ROOT/include" \
	-i "$ROOT/tools/sourcemod/include" \
	-o "$OUT_DIR/gokz-replays.smx"

echo "Built: $OUT_DIR/gokz-replays.smx"
