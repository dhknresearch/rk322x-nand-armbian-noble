#!/usr/bin/env python3
# Wire the old RK322x 4.4 target into a current Armbian checkout.
# The patch fails loudly when upstream markers move rather than silently
# producing an image with the wrong kernel.

from __future__ import annotations

import re
import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count == 0 and new in text:
        return text
    if count != 1:
        raise RuntimeError(f"{label}: expected one marker, found {count}")
    return text.replace(old, new, 1)


def patch_board(path: Path) -> None:
    text = path.read_text()
    text = re.sub(
        r'^KERNEL_TARGET="(?:current,edge|legacy,current,edge)"$',
        'KERNEL_TARGET="legacy,current,edge"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if 'KERNEL_TARGET="legacy,current,edge"' not in text:
        raise RuntimeError("board config: KERNEL_TARGET marker not found")
    path.write_text(text)


def patch_family(path: Path) -> None:
    text = path.read_text()

    text = replace_once(
        text,
        "\t# on non-legacy kernels\n\tenable_extension xorg-lima-serverflags",
        "\t# on non-legacy kernels\n"
        "\tif [[ \"$BRANCH\" != \"legacy\" ]]; then\n"
        "\t\tenable_extension xorg-lima-serverflags\n"
        "\tfi",
        "Lima extension guard",
    )

    legacy_case = '''\tlegacy)\n\n\t\t# Raw NAND support for RK322x exists only in the old vendor kernel.\n\t\tdeclare -g LINUXFAMILY="rk322x"\n\t\tdeclare -g KERNEL_MAJOR_MINOR="4.4"\n\t\tKERNELSOURCE='https://github.com/armbian/linux'\n\t\tKERNELBRANCH='branch:stable-4.4-rk3288-linux-v2.x'\n\t\tKERNELDIR='linux-rockchip'\n\t\tKERNELPATCHDIR='archive/rk322x-4.4'\n\t\t;;\n\n'''
    vendor_marker = "case $BRANCH in\n\n\tvendor)"
    if "KERNELPATCHDIR='archive/rk322x-4.4'" not in text:
        text = replace_once(
            text,
            vendor_marker,
            "case $BRANCH in\n\n" + legacy_case + "\tvendor)",
            "legacy kernel case",
        )

    old_freq = 'CPUMIN="600000"\nCPUMAX="1900000"\nGOVERNOR="ondemand"'
    new_freq = '''if [[ "$BOOT_SOC" == "rk322x" ]]; then
\t# Preserve the old family ceiling; runtime customization caps it further.
\tCPUMIN="600000"
\tCPUMAX="1500000"
else
\tCPUMIN="600000"
\tCPUMAX="1900000"
fi
GOVERNOR="ondemand"'''
    text = replace_once(text, old_freq, new_freq, "RK322x CPU defaults")

    legacy_bsp = '''
\t# Vendor-kernel-only RK322x helpers removed with the legacy target.
\tif [[ "$BOARD" == "rk322x-box" && "$BRANCH" == "legacy" ]]; then
\t\tmkdir -p "$destination/etc/modprobe.d"
\t\tinstall -m 644 "$SRC/packages/bsp/rk322x/esp8089.conf" \\
\t\t\t"$destination/etc/modprobe.d/esp8089.conf"
\t\tinstall -m 644 "$SRC/packages/bsp/rk322x/50-rkvdec.rules" \\
\t\t\t"$destination/etc/udev/rules.d/50-rkvdec.rules"
\tfi
'''
    marker = "\t# Board selection script, only for rk322x-box\n"
    if "Vendor-kernel-only RK322x helpers" not in text:
        text = replace_once(text, marker, legacy_bsp + "\n" + marker, "legacy BSP helpers")

    path.write_text(text)


def patch_kernel_compile(path: Path) -> None:
    text = path.read_text()
    if "rk322x-legacy-postpatch.py" in text:
        if text.count("rk322x-legacy-postpatch.py") != 1:
            raise RuntimeError("kernel compile: expected exactly one RK322x post-patch hook")
        return

    # Insert after the semantic patching step in compile_kernel(), rather than
    # depending on kernel-patching.sh's internal logging/formatting layout.
    # Armbian has repeatedly changed that internal line while keeping the
    # standalone kernel_main_patching invocation stable.
    marker = re.compile(
        r'(?m)^(?P<indent>[ \t]*)kernel_main_patching(?P<comment>[ \t]+#.*)?[ \t]*$'
    )
    matches = list(marker.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(
            "kernel compile: expected exactly one kernel_main_patching call, "
            f"found {len(matches)}"
        )

    match = matches[0]
    indent = match.group("indent")
    hook_lines = [
        "",
        f"{indent}# Sanitize the fully patched RK322x 4.4 source for modern tools.",
        f'{indent}if [[ "${{LINUXFAMILY}}" == "rk322x" && "${{BRANCH}}" == "legacy" ]]; then',
        f'{indent}\trun_host_command_logged python3 \\',
        f'{indent}\t\t"${{SRC}}/userpatches/rk322x-legacy-postpatch.py" "${{kernel_work_dir}}"',
        f"{indent}fi",
    ]
    insertion = "\n".join(hook_lines)
    text = text[: match.end()] + insertion + text[match.end() :]

    if text.count("rk322x-legacy-postpatch.py") != 1:
        raise RuntimeError("kernel compile: expected exactly one RK322x post-patch hook")
    path.write_text(text)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/armbian-build", file=sys.stderr)
        return 64

    root = Path(sys.argv[1]).resolve()
    board = root / "config/boards/rk322x-box.tvb"
    family = root / "config/sources/families/rockchip.conf"
    kernel_compile = root / "lib/functions/compilation/kernel.sh"
    for path in (board, family, kernel_compile):
        if not path.is_file():
            raise FileNotFoundError(path)

    patch_board(board)
    patch_family(family)
    patch_kernel_compile(kernel_compile)

    board_text = board.read_text()
    family_text = family.read_text()
    kernel_compile_text = kernel_compile.read_text()
    required = {
        "legacy board target": 'KERNEL_TARGET="legacy,current,edge"' in board_text,
        "4.4 kernel source": 'KERNEL_MAJOR_MINOR="4.4"' in family_text,
        "legacy family name": 'LINUXFAMILY="rk322x"' in family_text,
        "legacy patches": "KERNELPATCHDIR='archive/rk322x-4.4'" in family_text,
        "legacy Wi-Fi config": "esp8089.conf" in family_text,
        "legacy VPU rule": "50-rkvdec.rules" in family_text,
        "Lima legacy exclusion": '"$BRANCH" != "legacy"' in family_text,
        "post-patch source sanitizer": "rk322x-legacy-postpatch.py" in kernel_compile_text,
    }
    missing = [name for name, ok in required.items() if not ok]
    if missing:
        raise RuntimeError("postcondition failed: " + ", ".join(missing))

    print("Framework patch checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"patch_framework.py: {exc}", file=sys.stderr)
        raise SystemExit(1)
