#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

status=0

# Verify only files maintained by this builder.  The work/ directory contains
# a complete upstream Armbian checkout and generated package files; linting it
# would report unrelated upstream warnings and can make verification fail after
# the first build has populated work/.
mapfile -d '' -t syntax_shell_scripts < <(
    find "$SCRIPT_DIR" \
        -path "$SCRIPT_DIR/work" -prune -o \
        -path "$SCRIPT_DIR/.git" -prune -o \
        -type f -name '*.sh' -print0 | sort -z
)

# Fixtures are syntax-checked, but they intentionally reference variables and
# functions supplied by Armbian at runtime, so they are excluded from ShellCheck.
mapfile -d '' -t lint_shell_scripts < <(
    find "$SCRIPT_DIR" \
        -path "$SCRIPT_DIR/work" -prune -o \
        -path "$SCRIPT_DIR/.git" -prune -o \
        -path "$SCRIPT_DIR/tests/fixtures" -prune -o \
        -type f -name '*.sh' -print0 | sort -z
)

for script in "${syntax_shell_scripts[@]}"; do
    echo "bash -n: ${script#"$SCRIPT_DIR"/}"
    bash -n "$script" || status=1
done

python3 -m py_compile "$SCRIPT_DIR/lib/patch_framework.py"
python3 -m py_compile "$SCRIPT_DIR/lib/tune_kernel_config.py"
python3 -m py_compile "$SCRIPT_DIR/userpatches/rk322x-legacy-postpatch.py"

dtc_patch="$SCRIPT_DIR/patches/zzzz-fix-dtc-yylloc-modern-gcc.patch"
test -s "$dtc_patch"
grep -q 'scripts/dtc/dtc-lexer.l' "$dtc_patch"
grep -q 'scripts/dtc/dtc-lexer.lex.c_shipped' "$dtc_patch"
grep -q 'patch/kernel/archive/rk322x-4.4/0001-fixing-dtc-error.patch' \
        "$SCRIPT_DIR/prepare-framework.sh" || {
    echo "prepare-framework.sh does not replace the historical DTC patch" >&2
    exit 1
}
if grep -q 'rk322x-4.4/zzzz-fix-dtc-yylloc-modern-gcc.patch' \
        "$SCRIPT_DIR/prepare-framework.sh"; then
    echo "prepare-framework.sh would append a conflicting second DTC patch" >&2
    exit 1
fi

# Apply the DTC patch to a representative Linux 4.4 source layout.  Both the
# Flex source and the generated shipped C lexer must lose the duplicate symbol.
dtc_fixture="$(mktemp -d)"
mkdir -p "$dtc_fixture/scripts/dtc"
cat > "$dtc_fixture/scripts/dtc/dtc-lexer.l" <<'EOF'
LINECOMMENT "//".*\n
%{
#include "dtc.h"
#include "srcpos.h"
#include "dtc-parser.tab.h"

YYLTYPE yylloc;
extern bool treesource_error;

/* CAUTION: this will stop working if we ever use yyless() or yyunput() */
EOF
cat > "$dtc_fixture/scripts/dtc/dtc-lexer.lex.c_shipped" <<'EOF'
char *yytext;
#include "dtc.h"
#include "srcpos.h"
#include "dtc-parser.tab.h"

YYLTYPE yylloc;
extern bool treesource_error;

/* CAUTION: this will stop working if we ever use yyless() or yyunput() */
EOF
patch -d "$dtc_fixture" -p1 --batch --forward < "$dtc_patch" >/dev/null
if grep -q '^YYLTYPE yylloc;' \
        "$dtc_fixture/scripts/dtc/dtc-lexer.l" \
        "$dtc_fixture/scripts/dtc/dtc-lexer.lex.c_shipped"; then
    echo "DTC compatibility patch left a duplicate yylloc definition" >&2
    exit 1
fi
rm -rf "$dtc_fixture"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/config/boards" "$fixture/config/sources/families" \
    "$fixture/lib/functions/compilation"
cp "$SCRIPT_DIR/tests/fixtures/rk322x-box.tvb" "$fixture/config/boards/"
cp "$SCRIPT_DIR/tests/fixtures/rockchip.conf" "$fixture/config/sources/families/"
cp "$SCRIPT_DIR/tests/fixtures/kernel-patching.sh" \
    "$fixture/lib/functions/compilation/kernel-patching.sh"
cp "$SCRIPT_DIR/tests/fixtures/kernel.sh" \
    "$fixture/lib/functions/compilation/kernel.sh"
python3 "$SCRIPT_DIR/lib/patch_framework.py" "$fixture"
python3 "$SCRIPT_DIR/lib/patch_framework.py" "$fixture"  # idempotence


# Also verify a minimal compile_kernel layout without an inline comment.
alternate_layout_fixture="$(mktemp -d)"
mkdir -p "$alternate_layout_fixture/config/boards"     "$alternate_layout_fixture/config/sources/families"     "$alternate_layout_fixture/lib/functions/compilation"
cp "$SCRIPT_DIR/tests/fixtures/rk322x-box.tvb"     "$alternate_layout_fixture/config/boards/"
cp "$SCRIPT_DIR/tests/fixtures/rockchip.conf"     "$alternate_layout_fixture/config/sources/families/"
cat > "$alternate_layout_fixture/lib/functions/compilation/kernel.sh" <<'EOF'
#!/usr/bin/env bash
function compile_kernel() {
    kernel_main_patching
    kernel_config
}
EOF
python3 "$SCRIPT_DIR/lib/patch_framework.py" "$alternate_layout_fixture"
python3 "$SCRIPT_DIR/lib/patch_framework.py" "$alternate_layout_fixture"
grep -Fq 'rk322x-legacy-postpatch.py'     "$alternate_layout_fixture/lib/functions/compilation/kernel.sh"
rm -rf "$alternate_layout_fixture"

grep -q 'KERNEL_TARGET="legacy,current,edge"' "$fixture/config/boards/rk322x-box.tvb"
grep -q "KERNELPATCHDIR='archive/rk322x-4.4'" "$fixture/config/sources/families/rockchip.conf"
if grep -q "KERNELPATCHDIR='rk322x-4.4'" "$fixture/config/sources/families/rockchip.conf"; then
    echo "Legacy patch directory lost its required archive/ prefix" >&2
    exit 1
fi
grep -q 'CPUMAX="1500000"' "$fixture/config/sources/families/rockchip.conf"
literal_fetch_mode='KERNEL_FETCH_MODE="${KERNEL_FETCH_MODE:-shallow}"'
literal_kernel_git='KERNEL_GIT="$KERNEL_GIT_MODE"'
grep -Fq "$literal_fetch_mode" "$SCRIPT_DIR/build.sh"
grep -Fq "$literal_kernel_git" "$SCRIPT_DIR/build.sh"
grep -q 'LEGACY_PATCH_REL="archive/rk322x-4.4"' "$SCRIPT_DIR/build.sh"
grep -Fq 'rk322x-legacy-postpatch.py' \
    "$fixture/lib/functions/compilation/kernel.sh"

# Wrappers may use a conventional bare -- separator, but build.sh must strip it
# before calling Armbian. Current Armbian rejects it as an unknown argument.
grep -Fq 'if [[ "${1:-}" == "--" ]]' "$SCRIPT_DIR/build.sh"
grep -Fq 'ARMBIAN_BUILD_UUID="$BUILD_UUID"' "$SCRIPT_DIR/build.sh"
grep -Fq 'debug-latest-build.sh" "$diagnostic" "$BUILD_UUID"' "$SCRIPT_DIR/build.sh"
grep -Fq 'RK322X_APT_MODE="${RK322X_APT_MODE:-direct}"' "$SCRIPT_DIR/build.sh"
grep -Fq 'APT_BUILD_ARGS+=(MANAGE_ACNG=no APT_PROXY_ADDR=)' "$SCRIPT_DIR/build.sh"

# Diagnostics tied to a build UUID must never fall back to an older unrelated
# log. Verify both exact selection and the missing-current-log failure path.
debug_fixture="$(mktemp -d)"
mkdir -p "$debug_fixture/work/armbian-build/output/logs"
printf 'old fatal error: stale\n' > "$debug_fixture/work/armbian-build/output/logs/log-build-old.log.ans"
printf 'new error: current\n' > "$debug_fixture/work/armbian-build/output/logs/log-build-current.log.ans"
WORK_ROOT="$debug_fixture/work" "$SCRIPT_DIR/debug-latest-build.sh" \
    "$debug_fixture/report.txt" current >/dev/null
grep -Fq 'log-build-current.log.ans' "$debug_fixture/report.txt"
if WORK_ROOT="$debug_fixture/work" "$SCRIPT_DIR/debug-latest-build.sh" \
        "$debug_fixture/missing.txt" missing >/dev/null 2>&1; then
    echo "Diagnostics incorrectly fell back to an older build log" >&2
    exit 1
fi
rm -rf "$debug_fixture"

# Verify that the direct fallback creates the exact normal-repository layout
# expected by Armbian's `git worktree add ... master --no-checkout` logic.
mkdir -p "$fixture/seed-src" "$fixture/seed-armbian"
git -C "$fixture/seed-src" init -q --initial-branch=stable-4.4-rk3288-linux-v2.x
git -C "$fixture/seed-src" config user.email test@example.invalid
git -C "$fixture/seed-src" config user.name Test
printf 'VERSION = 4\nPATCHLEVEL = 4\n' > "$fixture/seed-src/Makefile"
git -C "$fixture/seed-src" add Makefile
git -C "$fixture/seed-src" commit -qm init
git -C "$fixture/seed-armbian" init -q
RK322X_KERNEL_REPOSITORY="file://$fixture/seed-src" \
    "$SCRIPT_DIR/seed-kernel-4.4-direct.sh" "$fixture/seed-armbian"
seed_cache="$fixture/seed-armbian/cache/git-bare/shallow-kernel-4.4"
seed_work="$fixture/seed-armbian/cache/sources/linux-kernel-worktree/4.4__rk322x__arm"
mkdir -p "$(dirname "$seed_work")"
git -C "$seed_cache" worktree add "$seed_work" master --no-checkout --force >/dev/null
git -C "$seed_work" checkout -fq refs/remotes/origin/stable-4.4-rk3288-linux-v2.x
grep -q 'VERSION = 4' "$seed_work/Makefile"


# Modern-toolchain fixes run after the complete historical patch series. This
# fixture deliberately varies whitespace to prove the sanitizer does not rely
# on normal patch context or exact indentation.
postpatch_fixture="$(mktemp -d)"
mkdir -p \
    "$postpatch_fixture/arch/arm/boot/compressed" \
    "$postpatch_fixture/arch/arm/mm" \
    "$postpatch_fixture/drivers/net/wireless/rockchip_wlan/ssv6xxx/smac" \
    "$postpatch_fixture/drivers/net/wireless/ssv6x5x/smac"
printf 'VERSION = 4\nPATCHLEVEL = 4\n' > "$postpatch_fixture/Makefile"
cat > "$postpatch_fixture/arch/arm/boot/compressed/head.S" <<'EOF'
.macro debug_reloc_end
.endm

        .section   ".start" ,  #alloc , #execinstr
EOF
cat > "$postpatch_fixture/arch/arm/boot/compressed/piggy.gzip.S" <<'EOF'
        .section .piggydata,#alloc
        .globl input_data
input_data:
        .incbin "arch/arm/boot/compressed/piggy.gzip"
        .globl input_data_end
input_data_end:
EOF
cat > "$postpatch_fixture/arch/arm/mm/proc-v7.S" <<'EOF'
__v7_setup_stack:
	string	cpu_elf_name, "v7"
	.align

	.section ".proc.info.init", #alloc
EOF
for driver in \
    "$postpatch_fixture/drivers/net/wireless/rockchip_wlan/ssv6xxx/smac/dev.c" \
    "$postpatch_fixture/drivers/net/wireless/ssv6x5x/smac/dev.c"
do
    cat > "$driver" <<'EOF'
static void select_crypto(struct ieee80211_sta *sta, int unicast,
                          struct vif_info *vif_info)
{
    if((sta->drv_priv != NULL) && (vif_info->if_type == NL80211_IFTYPE_AP)) {
        use_ap_key(sta->drv_priv);
    } else if((sta->drv_priv != NULL) && (unicast == 1)) {
        use_sta_key(sta->drv_priv);
    }
}
EOF
done
python3 "$SCRIPT_DIR/userpatches/rk322x-legacy-postpatch.py" "$postpatch_fixture"
python3 "$SCRIPT_DIR/userpatches/rk322x-legacy-postpatch.py" "$postpatch_fixture"
grep -Eq '^[[:space:]]*\.section[[:space:]]+"\.start"[[:space:]]*,[[:space:]]*"ax"' \
    "$postpatch_fixture/arch/arm/boot/compressed/head.S"
grep -Eq '^[[:space:]]*\.section[[:space:]]+"\.proc\.info\.init"[[:space:]]*,[[:space:]]*"a"' \
    "$postpatch_fixture/arch/arm/mm/proc-v7.S"
grep -Eq '^[[:space:]]*\.section[[:space:]]+"?\.piggydata"?[[:space:]]*,[[:space:]]*"a"' \
    "$postpatch_fixture/arch/arm/boot/compressed/piggy.gzip.S"
if grep -Fq '#alloc' "$postpatch_fixture/arch/arm/boot/compressed/piggy.gzip.S"; then
    echo "Post-patch sanitizer left legacy piggy section syntax" >&2
    exit 1
fi
if grep -R -Fq 'sta->drv_priv != NULL' \
        "$postpatch_fixture/drivers/net/wireless/rockchip_wlan/ssv6xxx/smac/dev.c" \
        "$postpatch_fixture/drivers/net/wireless/ssv6x5x/smac/dev.c"; then
    echo "Post-patch sanitizer left impossible SSV drv_priv checks" >&2
    exit 1
fi
rm -rf "$postpatch_fixture"

grep -Fq 'rk322x-legacy-postpatch.py' "$SCRIPT_DIR/lib/patch_framework.py"
grep -Fq 'rm -f patch/kernel/archive/rk322x-4.4/zzzy-modern-binutils-ssv-compat.patch' \
    "$SCRIPT_DIR/prepare-framework.sh"
obsolete_install='install -m 644 "$SCRIPT_DIR/patches/zzzy-modern-binutils-ssv-compat.patch"'
if grep -Fq "$obsolete_install" \
        "$SCRIPT_DIR/prepare-framework.sh"; then
    echo "prepare-framework.sh still installs the fragile compatibility patch" >&2
    exit 1
fi

config_fixture="$(mktemp)"
cat > "$config_fixture" <<'EOF'
CONFIG_RTL8188EU=m
CONFIG_88XXAU=m
CONFIG_RTL8812AU=m
CONFIG_RTL8811CU=m
EOF
python3 "$SCRIPT_DIR/lib/tune_kernel_config.py" "$config_fixture" >/dev/null
grep -Fq '# CONFIG_88XXAU is not set' "$config_fixture"
grep -Fq '# CONFIG_RTL8812AU is not set' "$config_fixture"
if grep -Eq '^CONFIG_(88XXAU|RTL8812AU|RTL8812_AU)(_[A-Z0-9_]+)?=(y|m)$' "$config_fixture"; then
    echo "Incompatible RTL8812AU alias remains enabled" >&2
    exit 1
fi
grep -Fq 'CONFIG_RTL8188EU=m' "$config_fixture"
grep -Fq 'CONFIG_RTL8811CU=m' "$config_fixture"
for required in \
    CONFIG_DEVTMPFS=y \
    CONFIG_CGROUPS=y \
    CONFIG_FHANDLE=y \
    CONFIG_NAMESPACES=y \
    CONFIG_USER_NS=y \
    CONFIG_NET_NS=y \
    CONFIG_SECCOMP=y \
    CONFIG_SECCOMP_FILTER=y \
    'CONFIG_UEVENT_HELPER_PATH=""'; do
    grep -Fq "$required" "$config_fixture" || {
        echo "Missing userspace compatibility config: $required" >&2
        exit 1
    }
done
grep -Fq '# CONFIG_SYSFS_DEPRECATED is not set' "$config_fixture"
grep -Fq '# CONFIG_FW_LOADER_USER_HELPER is not set' "$config_fixture"
rm -f "$config_fixture"


# Desktop recovery must be present in the image and must not race Armbian's
# initial user-creation wizard.
desktop_recover="$SCRIPT_DIR/userpatches/overlay/usr/local/sbin/rk322x-desktop-recover"
desktop_service="$SCRIPT_DIR/userpatches/overlay/etc/systemd/system/rk322x-desktop-recover.service"
nm_wait_dropin="$SCRIPT_DIR/userpatches/overlay/etc/systemd/system/NetworkManager-wait-online.service.d/10-rk322x-timeout.conf"
test -x "$desktop_recover"
test -s "$desktop_service"
test -s "$nm_wait_dropin"
grep -Fq '/root/.not_logged_in_yet' "$desktop_recover"
grep -Fq 'systemctl set-default graphical.target' "$desktop_recover"
grep -Fq 'systemctl restart lightdm.service' "$desktop_recover"
grep -Fq 'PRESET_CONNECT_WIRELESS=n' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'systemctl enable rk322x-desktop-recover.service' "$SCRIPT_DIR/userpatches/customize-image.sh"
gui_extension="$SCRIPT_DIR/userpatches/extensions/rk322x-gui-packages.sh"
test -s "$gui_extension"
grep -Fq 'ENABLE_EXTENSIONS=rk322x-gui-packages' "$SCRIPT_DIR/build.sh"
if grep -Fq 'EXTRA_PACKAGES_IMAGE=' "$SCRIPT_DIR/build.sh"; then
    echo "build.sh still injects EXTRA_PACKAGES_IMAGE without provenance refs" >&2
    exit 1
fi
mapfile -t gui_packages < <(
    bash -c '''
        set -Eeuo pipefail
        display_alert() { :; }
        add_packages_to_image() { printf "%s\n" "$@"; }
        source "$1"
        extension_prepare_config__rk322x_gui_packages
    ''' _ "$gui_extension"
)
expected_gui_packages=(lightdm-gtk-greeter xserver-xorg-video-fbdev)
if [[ "${gui_packages[*]}" != "${expected_gui_packages[*]}" ]]; then
    printf "Unexpected GUI extension package list: %s\n" "${gui_packages[*]}" >&2
    exit 1
fi


# Resolute/Linux-4.4 compatibility backport: exact Ubuntu systemd 257.9 stack,
# forced legacy cgroups, and first-boot diagnostics.
resolute_builder="$SCRIPT_DIR/build-resolute-4.4.sh"
backport_installer="$SCRIPT_DIR/userpatches/overlay/usr/local/sbin/rk322x-install-systemd257-backport"
resolute_diag="$SCRIPT_DIR/userpatches/overlay/usr/local/sbin/rk322x-resolute-diagnostics"
resolute_diag_service="$SCRIPT_DIR/userpatches/overlay/etc/systemd/system/rk322x-resolute-diagnostics.service"
test -x "$resolute_builder"
test -x "$backport_installer"
test -x "$resolute_diag"
test -s "$resolute_diag_service"
grep -Fq 'resolute-4.4' "$SCRIPT_DIR/build.sh"
grep -Fq 'RELEASE=resolute' "$SCRIPT_DIR/build.sh"
grep -Fq '/usr/local/sbin/rk322x-install-systemd257-backport' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'append_boot_arg audit=0' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'systemd-networkd.service' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'systemd-oomd.service' "$SCRIPT_DIR/userpatches/customize-image.sh"
backport_plan="$($backport_installer --print-plan)"
grep -Fq 'version=257.9-0ubuntu2.5' <<<"$backport_plan"
grep -Fq 'suite=questing' <<<"$backport_plan"
grep -Fq 'core=systemd systemd-sysv udev libsystemd-shared libsystemd0 libudev1 libpam-systemd libnss-systemd' <<<"$backport_plan"
grep -Fq 'Pin-Priority: 1001' "$backport_installer"
grep -Fq 'apt-mark hold' "$backport_installer"
grep -Fq 'Acquire::http::Proxy=DIRECT' "$backport_installer"
grep -Fq 'Acquire::https::Proxy=DIRECT' "$backport_installer"
grep -Fq 'write_source https://ports.ubuntu.com/ubuntu-ports' "$backport_installer"
grep -Fq 'Acquire::http::Proxy "DIRECT"' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'Acquire::https::Proxy "DIRECT"' "$SCRIPT_DIR/userpatches/customize-image.sh"
grep -Fq 'rk322x-resolute-diagnostics.txt' "$resolute_diag"

"$SCRIPT_DIR/tests/integration-build-smoke.sh"

if command -v shellcheck >/dev/null 2>&1; then
    echo "Running shellcheck on builder-owned scripts"
    # SC1091: runtime source file intentionally unavailable during static lint.
    if ((${#lint_shell_scripts[@]} > 0)); then
        shellcheck -e SC1091 "${lint_shell_scripts[@]}" || status=1
    fi
else
    echo "shellcheck not installed; skipped"
fi

if [[ $status -ne 0 ]]; then
    echo "Verification failed" >&2
    exit "$status"
fi

echo "All static and fixture checks passed"
