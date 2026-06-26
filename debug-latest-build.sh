#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARMBIAN_DIR="${ARMBIAN_DIR:-${WORK_ROOT:-$SCRIPT_DIR/work}/armbian-build}"
LOG_DIR="$ARMBIAN_DIR/output/logs"
OUT="${1:-$SCRIPT_DIR/rk3229-first-errors.txt}"
BUILD_UUID="${2:-}"

if [[ -n "$BUILD_UUID" ]]; then
    LOG="$LOG_DIR/log-build-$BUILD_UUID.log.ans"
    [[ -f "$LOG" ]] || {
        echo "No ANSI log was created for current build UUID: $BUILD_UUID" >&2
        exit 1
    }
else
    LOG="$(find "$LOG_DIR" -maxdepth 1 -type f -name 'log-build-*.log.ans' \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$LOG" && -f "$LOG" ]] || {
        echo "No Armbian ANSI build log found under: $LOG_DIR" >&2
        exit 1
    }
fi

CLEAN="$(mktemp)"
trap 'rm -f "$CLEAN"' EXIT
perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g' "$LOG" > "$CLEAN"

{
    echo "Source log: $LOG"
    echo
    grep -nEi -B18 -A40 \
        'fatal error:|(^|[[:space:]])error:|undefined reference|collect2:|No rule to make target|internal compiler error|Summary of failed patches|Hunk #[0-9]+ FAILED' \
        "$CLEAN" | head -n 500 || true
    echo
    echo '--- Final 120 log lines ---'
    tail -n 120 "$CLEAN"
} > "$OUT"

echo "Wrote build diagnostics: $OUT"
