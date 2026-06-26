#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-noble}"
if [[ $# -gt 0 ]]; then shift; fi
# Accept the conventional wrapper separator used by documented commands, but
# never forward it to Armbian, whose current CLI treats a bare -- as unknown.
if [[ "${1:-}" == "--" ]]; then
    shift
fi

case "$PROFILE" in
    noble)
        RELEASE=noble
        RESOLUTE_BACKPORT=no
        ;;
    resolute-4.4|resolute-experimental)
        RELEASE=resolute
        RESOLUTE_BACKPORT=yes
        ;;
    *)
        echo "Unknown profile: $PROFILE" >&2
        echo "Valid profiles: noble, resolute-4.4" >&2
        exit 64
        ;;
esac

for cmd in git rsync python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing required host command: $cmd" >&2
        exit 127
    }
done

ARMBIAN_REF="${ARMBIAN_REF:-main}"
WORK_ROOT="${WORK_ROOT:-$SCRIPT_DIR/work}"
ARMBIAN_DIR="${ARMBIAN_DIR:-$WORK_ROOT/armbian-build}"
PREFER_DOCKER="${PREFER_DOCKER:-yes}"
ARMBIAN_REPOSITORY="${ARMBIAN_REPOSITORY:-https://github.com/armbian/build.git}"
KERNEL_FETCH_MODE="${KERNEL_FETCH_MODE:-shallow}"
# Current Armbian can inherit or auto-discover apt-cacher-ng through
# APT_PROXY_ADDR/MANAGE_ACNG. A stale LAN cache makes apt report every package
# as missing. Default to direct APT for this reproducible RK322x build; users
# who genuinely need a proxy can opt back in with RK322X_APT_MODE=inherit.
RK322X_APT_MODE="${RK322X_APT_MODE:-direct}"
APT_BUILD_ARGS=()
case "$RK322X_APT_MODE" in
    direct)
        APT_TRANSPORT_LABEL=direct
        APT_BUILD_ARGS+=(MANAGE_ACNG=no APT_PROXY_ADDR=)
        ;;
    inherit)
        APT_TRANSPORT_LABEL="inherit${APT_PROXY_ADDR:+ ($APT_PROXY_ADDR)}"
        [[ -v MANAGE_ACNG ]] && APT_BUILD_ARGS+=("MANAGE_ACNG=$MANAGE_ACNG")
        [[ -v APT_PROXY_ADDR ]] && APT_BUILD_ARGS+=("APT_PROXY_ADDR=$APT_PROXY_ADDR")
        ;;
    *)
        echo "Unknown RK322X_APT_MODE: $RK322X_APT_MODE" >&2
        echo "Valid modes: direct, inherit" >&2
        exit 64
        ;;
esac

case "$KERNEL_FETCH_MODE" in
    shallow)
        KERNEL_GIT_MODE=shallow
        ;;
    direct)
        KERNEL_GIT_MODE=shallow
        ;;
    full)
        KERNEL_GIT_MODE=full
        ;;
    *)
        echo "Unknown KERNEL_FETCH_MODE: $KERNEL_FETCH_MODE" >&2
        echo "Valid modes: shallow, direct, full" >&2
        exit 64
        ;;
esac

mkdir -p "$WORK_ROOT"

if [[ ! -d "$ARMBIAN_DIR/.git" ]]; then
    if [[ -e "$ARMBIAN_DIR" ]]; then
        echo "ARMBIAN_DIR exists but is not a git checkout: $ARMBIAN_DIR" >&2
        exit 1
    fi
    echo "==> Cloning current Armbian framework"
    if ! git clone --depth=1 --branch "$ARMBIAN_REF" \
        "$ARMBIAN_REPOSITORY" "$ARMBIAN_DIR"; then
        # A raw commit SHA cannot be used with --branch. Git may leave a
        # partial directory behind after that expected failure.
        rm -rf "$ARMBIAN_DIR"
        git clone --depth=1 "$ARMBIAN_REPOSITORY" "$ARMBIAN_DIR"
    fi
fi

cd "$ARMBIAN_DIR"
echo "==> Updating disposable framework checkout to: $ARMBIAN_REF"
git fetch --no-tags --depth=1 origin "$ARMBIAN_REF"
git checkout --detach --force FETCH_HEAD
git reset --hard FETCH_HEAD

# Remove only files/directories this bundle may have added. Keep Armbian caches/output.
rm -rf \
    config/kernel/linux-rk322x-legacy.config \
    patch/kernel/archive/rk322x-4.4 \
    userpatches

git checkout -- config/boards/rk322x-box.tvb config/sources/families/rockchip.conf \
    packages/bsp/rk322x 2>/dev/null || true

rsync -a --delete "$SCRIPT_DIR/userpatches/" "$ARMBIAN_DIR/userpatches/"
"$SCRIPT_DIR/prepare-framework.sh" "$ARMBIAN_DIR"

# Current Armbian interprets KERNELPATCHDIR relative to patch/kernel.  The
# recovered RK322x series lives below patch/kernel/archive, so omitting the
# archive/ component silently produces an unpatched vendor kernel.
LEGACY_PATCH_REL="archive/rk322x-4.4"
LEGACY_PATCH_DIR="$ARMBIAN_DIR/patch/kernel/$LEGACY_PATCH_REL"
DTC_COMPAT_PATCH="$LEGACY_PATCH_DIR/0001-fixing-dtc-error.patch"

if ! grep -Fq "KERNELPATCHDIR='$LEGACY_PATCH_REL'" \
        "$ARMBIAN_DIR/config/sources/families/rockchip.conf"; then
    echo "Legacy kernel patch path is not wired correctly: $LEGACY_PATCH_REL" >&2
    exit 1
fi
if [[ ! -d "$LEGACY_PATCH_DIR" ]]; then
    echo "Restored RK322x patch directory is missing: $LEGACY_PATCH_DIR" >&2
    exit 1
fi
if [[ ! -s "$DTC_COMPAT_PATCH" ]]; then
    echo "DTC/GCC compatibility patch is missing: $DTC_COMPAT_PATCH" >&2
    exit 1
fi
if ! grep -Fq 'scripts/dtc/dtc-lexer.l' "$DTC_COMPAT_PATCH" || \
        ! grep -Fq 'scripts/dtc/dtc-lexer.lex.c_shipped' "$DTC_COMPAT_PATCH"; then
    echo "DTC compatibility patch is not the expected two-file replacement" >&2
    exit 1
fi
POSTPATCH_SANITIZER="$ARMBIAN_DIR/userpatches/rk322x-legacy-postpatch.py"
KERNEL_COMPILE_SH="$ARMBIAN_DIR/lib/functions/compilation/kernel.sh"
LEGACY_CONFIG="$ARMBIAN_DIR/config/kernel/linux-rk322x-legacy.config"
if [[ ! -x "$POSTPATCH_SANITIZER" ]]; then
    echo "RK322x post-patch sanitizer is missing: $POSTPATCH_SANITIZER" >&2
    exit 1
fi
if ! grep -Fq 'rk322x-legacy-postpatch.py' "$KERNEL_COMPILE_SH"; then
    echo "Current framework is not wired to run the RK322x post-patch sanitizer" >&2
    exit 1
fi
if [[ -e "$LEGACY_PATCH_DIR/zzzy-modern-binutils-ssv-compat.patch" ]]; then
    echo "Fragile compatibility patch must not be present in the kernel series" >&2
    exit 1
fi
if grep -Eq '^CONFIG_(88XXAU|RTL8812AU|RTL8812_AU)(_[A-Z0-9_]+)?=(y|m)$' "$LEGACY_CONFIG"; then
    echo "Incompatible rtl8812au Kconfig symbol is still enabled in $LEGACY_CONFIG" >&2
    grep -En '^CONFIG_(88XXAU|RTL8812AU|RTL8812_AU)(_[A-Z0-9_]+)?=(y|m)$' \
        "$LEGACY_CONFIG" >&2 || true
    exit 1
fi
if ! grep -Fq '# CONFIG_88XXAU is not set' "$LEGACY_CONFIG"; then
    echo "Historical rtl8812au symbol CONFIG_88XXAU was not disabled" >&2
    exit 1
fi
LEGACY_PATCH_COUNT="$(find "$LEGACY_PATCH_DIR" -maxdepth 1 -type f \
    \( -name '*.patch' -o -name '*.diff' \) -printf '.' | wc -c)"
if (( LEGACY_PATCH_COUNT < 1 )); then
    echo "No kernel patches found under: $LEGACY_PATCH_DIR" >&2
    exit 1
fi
printf '==> Verified legacy patch discovery: %s (%s patch files)\n' \
    "$LEGACY_PATCH_REL" "$LEGACY_PATCH_COUNT"

# Clean only abandoned ORAS partial downloads. A completed cache is preserved.
rm -rf "$ARMBIAN_DIR/cache/git-bundles/kernel/"*.oras.pull.tmp 2>/dev/null || true

if [[ "$KERNEL_FETCH_MODE" == direct ]]; then
    "$SCRIPT_DIR/seed-kernel-4.4-direct.sh" "$ARMBIAN_DIR"
fi

BACKPORT_LABEL="none"
if [[ "$RESOLUTE_BACKPORT" == yes ]]; then
    BACKPORT_LABEL="Ubuntu systemd 257.9 + forced cgroup v1"
fi
cat <<EOF
==> Build profile
    release:          $RELEASE
    userspace bridge: $BACKPORT_LABEL
    kernel:           RK322x vendor 4.4 legacy
    desktop:          XFCE minimal tier
    framework ref:    $(git rev-parse --short HEAD)
    docker preferred: $PREFER_DOCKER
    kernel fetch:      $KERNEL_FETCH_MODE ($KERNEL_GIT_MODE tree)
    apt transport:     $APT_TRANSPORT_LABEL
EOF

# Add the two GUI recovery dependencies through a user extension. Current
# Armbian tracks a provenance reference for every package added to the image;
# the extension API keeps that list synchronized automatically.
BUILD_UUID="${ARMBIAN_BUILD_UUID:-$(python3 - <<'PYUUID'
import uuid
print(uuid.uuid4())
PYUUID
)}"

set +e
# In direct mode also remove generic proxy environment variables for the
# Armbian process. The explicit compile arguments below disable its managed
# apt-cacher-ng path and clear APT_PROXY_ADDR inside Docker/chroot stages.
if [[ "$RK322X_APT_MODE" == direct ]]; then
    unset APT_PROXY_ADDR MANAGE_ACNG http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
fi
./compile.sh build \
    BOARD=rk322x-box \
    BRANCH=legacy \
    RELEASE="$RELEASE" \
    BUILD_DESKTOP=yes \
    BUILD_MINIMAL=no \
    DESKTOP_ENVIRONMENT=xfce \
    DESKTOP_TIER=minimal \
    NETWORKING_STACK=network-manager \
    ENABLE_EXTENSIONS=rk322x-gui-packages \
    ROOTFS_TYPE=ext4 \
    KERNEL_CONFIGURE=no \
    KERNEL_BTF=no \
    INSTALL_HEADERS=no \
    BSPFREEZE=yes \
    KERNEL_GIT="$KERNEL_GIT_MODE" \
    EXPERT=yes \
    SHARE_LOG=yes \
    ARMBIAN_BUILD_UUID="$BUILD_UUID" \
    PREFER_DOCKER="$PREFER_DOCKER" \
    COMPRESS_OUTPUTIMAGE=sha,img,xz \
    "${APT_BUILD_ARGS[@]}" \
    "$@"
compile_status=$?
set -e

if (( compile_status != 0 )); then
    diagnostic="$SCRIPT_DIR/rk3229-first-errors.txt"
    if "$SCRIPT_DIR/debug-latest-build.sh" "$diagnostic" "$BUILD_UUID"; then
        echo >&2
        echo "==> First-order build diagnostics: $diagnostic" >&2
        sed -n '1,260p' "$diagnostic" >&2
    else
        echo "Build failed and no local ANSI log could be extracted" >&2
    fi
    exit "$compile_status"
fi

printf '\nBuild complete. Images, checksums and logs are under:\n  %s\n' \
    "$ARMBIAN_DIR/output/images"
