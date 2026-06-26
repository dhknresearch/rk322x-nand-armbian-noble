#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE="${1:-unknown}"
LINUXFAMILY="${2:-unknown}"
BOARD="${3:-unknown}"
BUILD_DESKTOP="${4:-unknown}"
ARCH="${5:-unknown}"

printf 'RK322x customization: release=%s family=%s board=%s desktop=%s arch=%s\n' \
    "$RELEASE" "$LINUXFAMILY" "$BOARD" "$BUILD_DESKTOP" "$ARCH"

if [[ "$BOARD" != "rk322x-box" ]]; then
    echo "Skipping RK322x overlay for unrelated board: $BOARD"
    exit 0
fi

# Armbian bind-mounts userpatches/overlay here while this script runs in chroot.
if [[ -d /tmp/overlay ]]; then
    cp -a /tmp/overlay/. /
fi

chmod 0755 /usr/local/sbin/rk322x-tune
chmod 0755 /usr/local/sbin/rk322x-desktop-recover
chmod 0755 /usr/local/sbin/rk322x-install-systemd257-backport
chmod 0755 /usr/local/sbin/rk322x-resolute-diagnostics
chmod 0644 /etc/systemd/system/rk322x-tune.service
chmod 0644 /etc/systemd/system/rk322x-desktop-recover.service
chmod 0644 /etc/systemd/system/rk322x-resolute-diagnostics.service

if [[ "$RELEASE" == "resolute" ]]; then
    # Resolute ships systemd 259, which removed cgroup-v1 and requires Linux
    # 5.4. Install Ubuntu's matched systemd 257.9 ARMHF stack, the last release
    # retaining an explicit legacy-cgroup escape hatch for Linux 4.4.
    /usr/local/sbin/rk322x-install-systemd257-backport
fi

# Enabling/disabling units is valid in an offline image even though systemd is
# not PID 1 inside the build chroot.
systemctl enable rk322x-tune.service 2>/dev/null || true
systemctl enable rk322x-desktop-recover.service 2>/dev/null || true
if [[ "$RELEASE" == "resolute" ]]; then
    systemctl enable rk322x-resolute-diagnostics.service 2>/dev/null || true
fi
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask systemd-oomd.service 2>/dev/null || true
systemctl mask systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl disable armbian-ramlog.service 2>/dev/null || true


# Avoid the long wireless/Internet probing path in Armbian's console wizard.
# The account setup completes first, XFCE starts, and Wi-Fi can then be selected
# from NetworkManager's panel applet. The recovery service handles a previous
# interrupted setup once the normal-user marker has been removed.
if [[ -f /root/.not_logged_in_yet ]] && \
        ! grep -Eq '^[[:space:]]*PRESET_CONNECT_WIRELESS=' /root/.not_logged_in_yet; then
    printf '\nPRESET_CONNECT_WIRELESS=n\n' >> /root/.not_logged_in_yet
fi

# Reduce writes to raw NAND without changing filesystem layout.
if [[ -f /etc/fstab ]]; then
    awk 'BEGIN { OFS="\t" }
         /^[[:space:]]*#/ || NF < 4 { print; next }
         $2 == "/" {
             if ($4 !~ /(^|,)noatime(,|$)/) $4=$4 ",noatime"
         }
         { print }' /etc/fstab > /etc/fstab.rk322x
    cat /etc/fstab.rk322x > /etc/fstab
    rm -f /etc/fstab.rk322x
fi

append_boot_arg() {
    local arg="$1" file=/boot/armbianEnv.txt current
    [[ -f "$file" ]] || return 0
    current="$(sed -n 's/^extraargs=//p' "$file" | tail -n1)"
    case " $current " in
        *" $arg "*) return 0 ;;
    esac
    if grep -q '^extraargs=' "$file"; then
        sed -i "s|^extraargs=.*|extraargs=${current:+$current }$arg|" "$file"
    else
        printf 'extraargs=%s\n' "$arg" >> "$file"
    fi
}

append_boot_arg transparent_hugepage=never
# The old Rockchip kernel has an incomplete early cgroup-v2 implementation.
append_boot_arg systemd.unified_cgroup_hierarchy=0
if [[ "$RELEASE" == "resolute" ]]; then
    # systemd 257 defaults away from legacy cgroups unless this explicit escape
    # hatch is present. Audit is disabled per upstream's old-kernel guidance.
    append_boot_arg SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1
    append_boot_arg audit=0
fi

# Never carry a build-host apt-cacher setting into the finished image. APT's
# documented DIRECT value overrides generic HTTP/HTTPS proxy settings.
cat > /etc/apt/apt.conf.d/00-rk322x-direct-apt <<'EOF'
Acquire::http::Proxy "DIRECT";
Acquire::https::Proxy "DIRECT";
EOF

# Keep package-manager defaults light for future manual installs, without
# purging anything the desktop build selected.
cat > /etc/apt/apt.conf.d/90-rk322x-light <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF

apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
