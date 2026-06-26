#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REMOTE="$TMP_ROOT/armbian-remote"
WORK_ROOT="$TMP_ROOT/work"

mkdir -p "$REMOTE"
git -C "$REMOTE" init -q --initial-branch=main
git -C "$REMOTE" config user.email test@example.invalid
git -C "$REMOTE" config user.name Test

# Legacy commit containing the pieces removed from current Armbian.
mkdir -p \
    "$REMOTE/config/kernel" \
    "$REMOTE/patch/kernel/archive/rk322x-4.4" \
    "$REMOTE/packages/bsp/rk322x"
cat > "$REMOTE/config/kernel/linux-rk322x-legacy.config" <<'CFG'
CONFIG_RTL8188EU=m
CONFIG_88XXAU=m
CONFIG_RTL8811CU=m
CFG
cat > "$REMOTE/patch/kernel/archive/rk322x-4.4/0001-fixing-dtc-error.patch" <<'PATCH'
placeholder historical patch replaced by prepare-framework.sh
PATCH
cat > "$REMOTE/patch/kernel/archive/rk322x-4.4/03-002-wifi-ssv6x5x-driver.patch" <<'PATCH'
diff --git a/drivers/net/wireless/ssv6x5x/smac/dev.c b/drivers/net/wireless/ssv6x5x/smac/dev.c
new file mode 100644
--- /dev/null
+++ b/drivers/net/wireless/ssv6x5x/smac/dev.c
@@ -0,0 +1,9 @@
+static void select_crypto(struct ieee80211_sta *sta, int unicast,
+                          struct vif_info *vif_info)
+{
+   if((sta->drv_priv != NULL) && (vif_info->if_type == NL80211_IFTYPE_AP)) {
+       use_ap_key(sta->drv_priv);
+   } else if((sta->drv_priv != NULL) && (unicast == 1)) {
+       use_sta_key(sta->drv_priv);
+   }
+}
PATCH
printf '%s\n' 'options esp8089 debug=0' > "$REMOTE/packages/bsp/rk322x/esp8089.conf"
printf '%s\n' 'SUBSYSTEM=="video4linux", MODE="0660"' > "$REMOTE/packages/bsp/rk322x/50-rkvdec.rules"
git -C "$REMOTE" add .
git -C "$REMOTE" commit -qm legacy
LEGACY_REF="$(git -C "$REMOTE" rev-parse HEAD)"

# Current-framework commit: legacy assets removed, board/family remain.
rm -rf \
    "$REMOTE/config/kernel/linux-rk322x-legacy.config" \
    "$REMOTE/patch/kernel/archive/rk322x-4.4" \
    "$REMOTE/packages/bsp/rk322x"
mkdir -p "$REMOTE/config/boards" "$REMOTE/config/sources/families" \
    "$REMOTE/lib/functions/compilation"
cp "$SCRIPT_DIR/tests/fixtures/rk322x-box.tvb" "$REMOTE/config/boards/"
cp "$SCRIPT_DIR/tests/fixtures/rockchip.conf" "$REMOTE/config/sources/families/"
cp "$SCRIPT_DIR/tests/fixtures/kernel-patching.sh" \
    "$REMOTE/lib/functions/compilation/kernel-patching.sh"
cp "$SCRIPT_DIR/tests/fixtures/kernel.sh" \
    "$REMOTE/lib/functions/compilation/kernel.sh"
cat > "$REMOTE/compile.sh" <<'COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
args=" $* "
[[ "$args" != *' -- '* ]] || {
    echo 'bare -- leaked into Armbian compile arguments' >&2
    exit 1
}
for proxy_var in APT_PROXY_ADDR MANAGE_ACNG http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
    [[ ! -v $proxy_var ]] || {
        echo "proxy environment leaked into Armbian compile: $proxy_var=${!proxy_var}" >&2
        exit 1
    }
done
for required in \
    ' BOARD=rk322x-box ' \
    ' BRANCH=legacy ' \
    ' BUILD_DESKTOP=yes ' \
    ' DESKTOP_ENVIRONMENT=xfce ' \
    ' DESKTOP_TIER=minimal ' \
    ' ENABLE_EXTENSIONS=rk322x-gui-packages ' \
    ' KERNEL_GIT=shallow ' \
    ' CLEAN_LEVEL=make-kernel ' \
    ' MANAGE_ACNG=no ' \
    ' APT_PROXY_ADDR= ' \
    ' ARMBIAN_BUILD_UUID='
do
    [[ "$args" == *"$required"* ]] || {
        echo "missing compile argument:$required" >&2
        exit 1
    }
done
if [[ "$args" != *' RELEASE=noble '* && "$args" != *' RELEASE=resolute '* ]]; then
    echo 'missing supported RELEASE=noble|resolute' >&2
    exit 1
fi
patch_dir='patch/kernel/archive/rk322x-4.4'
[[ -s "$patch_dir/0001-fixing-dtc-error.patch" ]]
[[ ! -e "$patch_dir/zzzy-modern-binutils-ssv-compat.patch" ]]
[[ -x userpatches/rk322x-legacy-postpatch.py ]]
[[ -s userpatches/extensions/rk322x-gui-packages.sh ]]
[[ -x userpatches/overlay/usr/local/sbin/rk322x-desktop-recover ]]
[[ -s userpatches/overlay/etc/systemd/system/rk322x-desktop-recover.service ]]
[[ -s userpatches/overlay/etc/systemd/system/NetworkManager-wait-online.service.d/10-rk322x-timeout.conf ]]
[[ -x userpatches/overlay/usr/local/sbin/rk322x-install-systemd257-backport ]]
[[ -x userpatches/overlay/usr/local/sbin/rk322x-resolute-diagnostics ]]
[[ -s userpatches/overlay/etc/systemd/system/rk322x-resolute-diagnostics.service ]]
grep -Fq 'PRESET_CONNECT_WIRELESS=n' userpatches/customize-image.sh
grep -Fq 'systemctl enable rk322x-desktop-recover.service' userpatches/customize-image.sh
grep -Fq 'add_packages_to_image' userpatches/extensions/rk322x-gui-packages.sh
grep -Fq '257.9-0ubuntu2.5' userpatches/overlay/usr/local/sbin/rk322x-install-systemd257-backport
grep -Fq 'SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1' userpatches/customize-image.sh
grep -Fq 'Acquire::http::Proxy "DIRECT"' userpatches/customize-image.sh
grep -Fq 'Acquire::https::Proxy "DIRECT"' userpatches/customize-image.sh
grep -Fq 'Acquire::http::Proxy=DIRECT' userpatches/overlay/usr/local/sbin/rk322x-install-systemd257-backport
[[ "$args" != *' EXTRA_PACKAGES_IMAGE='* ]] || {
    echo 'unsupported direct EXTRA_PACKAGES_IMAGE injection remains' >&2
    exit 1
}
grep -Fq 'rk322x-legacy-postpatch.py' \
    lib/functions/compilation/kernel.sh
grep -Fq '# CONFIG_88XXAU is not set' \
    config/kernel/linux-rk322x-legacy.config
if grep -Eq '^CONFIG_(88XXAU|RTL8812AU|RTL8812_AU)(_[A-Z0-9_]+)?=(y|m)$' \
        config/kernel/linux-rk322x-legacy.config; then
    echo 'incompatible rtl8812au alias remains enabled' >&2
    exit 1
fi
grep -Fq "KERNELPATCHDIR='archive/rk322x-4.4'" \
    config/sources/families/rockchip.conf
mkdir -p output/images
printf '%s\n' "$*" > output/images/smoke-compile.args
COMPILE
chmod +x "$REMOTE/compile.sh"
git -C "$REMOTE" add -A
git -C "$REMOTE" commit -qm current

WORK_ROOT="$WORK_ROOT" \
ARMBIAN_REPOSITORY="file://$REMOTE" \
ARMBIAN_REF=main \
RK322X_LEGACY_REF="$LEGACY_REF" \
PREFER_DOCKER=no \
KERNEL_FETCH_MODE=shallow \
APT_PROXY_ADDR='http://10.0.40.2:3142' \
MANAGE_ACNG='http://10.0.40.2:3142' \
http_proxy='http://10.0.40.2:3142' \
https_proxy='http://10.0.40.2:3142' \
    "$SCRIPT_DIR/build-noble.sh" -- CLEAN_LEVEL=make-kernel

test -s "$WORK_ROOT/armbian-build/output/images/smoke-compile.args"
grep -Fq 'RELEASE=noble' "$WORK_ROOT/armbian-build/output/images/smoke-compile.args"

WORK_ROOT="$WORK_ROOT" \
ARMBIAN_REPOSITORY="file://$REMOTE" \
ARMBIAN_REF=main \
RK322X_LEGACY_REF="$LEGACY_REF" \
PREFER_DOCKER=no \
KERNEL_FETCH_MODE=shallow \
APT_PROXY_ADDR='http://10.0.40.2:3142' \
MANAGE_ACNG='http://10.0.40.2:3142' \
HTTP_PROXY='http://10.0.40.2:3142' \
HTTPS_PROXY='http://10.0.40.2:3142' \
    "$SCRIPT_DIR/build-resolute-4.4.sh" -- CLEAN_LEVEL=make-kernel

grep -Fq 'RELEASE=resolute' "$WORK_ROOT/armbian-build/output/images/smoke-compile.args"
echo "Build-flow smoke test passed (Noble + Resolute-4.4)"
