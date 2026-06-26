#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' 'NOTE: build-resolute-experimental.sh now uses the systemd-257 Linux-4.4 compatibility backport.' >&2
exec "$SCRIPT_DIR/build.sh" resolute-4.4 "$@"
