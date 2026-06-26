#!/usr/bin/env bash
set -Eeuo pipefail

ARMBIAN_DIR="${1:?Usage: prepare-framework.sh /path/to/armbian-build}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_REF="${RK322X_LEGACY_REF:-f71a96b799be8b9fb2caf551b87da1b7373b0e84}"

[[ -d "$ARMBIAN_DIR/.git" ]] || {
    echo "Not an Armbian git checkout: $ARMBIAN_DIR" >&2
    exit 1
}

cd "$ARMBIAN_DIR"

echo "==> Fetching last Armbian revision that still contained RK322x legacy"
git fetch --no-tags --depth=1 origin "$LEGACY_REF"

restore_from_legacy() {
    local path="$1"
    if ! git cat-file -e "$LEGACY_REF:$path" 2>/dev/null; then
        echo "Required path is absent from legacy commit: $path" >&2
        exit 1
    fi
    rm -rf "$path"
    mkdir -p "$(dirname "$path")"
    git checkout "$LEGACY_REF" -- "$path"
}

# Kernel config and patch series include the GCC fixes made immediately before
# the legacy target was removed from Armbian.
restore_from_legacy config/kernel/linux-rk322x-legacy.config
restore_from_legacy patch/kernel/archive/rk322x-4.4

# Modern assembler and SSV source compatibility is applied after the full
# historical series by userpatches/rk322x-legacy-postpatch.py.  Do not append
# a normal patch here: earlier legacy patches can change whitespace/context.
rm -f patch/kernel/archive/rk322x-4.4/zzzy-modern-binutils-ssv-compat.patch

# The historical series already has 0001-fixing-dtc-error.patch, but it only
# changes the generated lexer declaration to extern. Replace that patch in
# place with the upstream-style two-file deletion.
install -m 644 "$SCRIPT_DIR/patches/zzzz-fix-dtc-yylloc-modern-gcc.patch" \
    patch/kernel/archive/rk322x-4.4/0001-fixing-dtc-error.patch

python3 "$SCRIPT_DIR/lib/tune_kernel_config.py" \
    config/kernel/linux-rk322x-legacy.config
restore_from_legacy packages/bsp/rk322x/esp8089.conf
restore_from_legacy packages/bsp/rk322x/50-rkvdec.rules

python3 "$SCRIPT_DIR/lib/patch_framework.py" "$ARMBIAN_DIR"

git rev-parse HEAD > .rk322x-current-framework-ref
printf '%s\n' "$LEGACY_REF" > .rk322x-legacy-source-ref

echo "==> RK322x Linux 4.4 target restored"
