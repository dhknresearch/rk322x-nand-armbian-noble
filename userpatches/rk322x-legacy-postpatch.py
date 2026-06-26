#!/usr/bin/env python3
"""Apply idempotent Linux 4.4 compatibility rewrites after Armbian patching.

The historical RK322x patch series is large and several patches modify nearby
ARM and wireless code.  Applying these small compatibility changes as a final
normal patch is brittle because whitespace/context can differ after the series.
This script runs after all kernel patches have been applied and rewrites only
known modern-toolchain incompatibilities in the resulting source tree.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


class RewriteError(RuntimeError):
    pass


def rewrite_section(
    path: Path,
    legacy_pattern: re.Pattern[str],
    fixed_pattern: re.Pattern[str],
    replacement: str,
    label: str,
) -> int:
    if not path.is_file():
        raise RewriteError(f"missing kernel source for {label}: {path}")

    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    legacy_before = len(legacy_pattern.findall(text))
    fixed_before = len(fixed_pattern.findall(text))

    if legacy_before == 0:
        if fixed_before == 0:
            raise RewriteError(
                f"{label}: neither legacy nor fixed section directive was found in {path}"
            )
        return 0

    rewritten, count = legacy_pattern.subn(replacement, text)
    if count != legacy_before:
        raise RewriteError(
            f"{label}: expected to rewrite {legacy_before} directive(s), rewrote {count}"
        )
    if legacy_pattern.search(rewritten):
        raise RewriteError(f"{label}: legacy section syntax remains in {path}")
    if not fixed_pattern.search(rewritten):
        raise RewriteError(f"{label}: fixed section syntax was not produced in {path}")

    path.write_text(rewritten, encoding="utf-8", errors="surrogateescape")
    return count


def rewrite_ssv(path: Path) -> int:
    if not path.is_file():
        raise RewriteError(f"missing SSV driver source: {path}")

    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    bad = re.compile(r"\(\s*sta->drv_priv\s*!=\s*NULL\s*\)\s*&&\s*")
    rewritten, count = bad.subn("", text)
    if bad.search(rewritten):
        raise RewriteError(f"impossible drv_priv NULL check remains in {path}")
    if count:
        path.write_text(rewritten, encoding="utf-8", errors="surrogateescape")
    return count


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/kernel-worktree", file=sys.stderr)
        return 64

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        raise RewriteError(f"not a kernel worktree: {root}")

    section_start_legacy = re.compile(
        r'(?m)^(?P<indent>[ \t]*)\.section[ \t]+"\.start"[ \t]*,'
        r'[ \t]*#alloc[ \t]*,[ \t]*#execinstr[ \t]*$'
    )
    section_start_fixed = re.compile(
        r'(?m)^[ \t]*\.section[ \t]+"\.start"[ \t]*,[ \t]*"ax"[ \t]*$'
    )
    section_proc_legacy = re.compile(
        r'(?m)^(?P<indent>[ \t]*)\.section[ \t]+"\.proc\.info\.init"'
        r'[ \t]*,[ \t]*#alloc[ \t]*$'
    )
    section_proc_fixed = re.compile(
        r'(?m)^[ \t]*\.section[ \t]+"\.proc\.info\.init"'
        r'[ \t]*,[ \t]*"a"[ \t]*$'
    )
    section_piggy_legacy = re.compile(
        r'(?m)^(?P<indent>[ \t]*)\.section[ \t]+"?\.piggydata"?'
        r'[ \t]*,[ \t]*#alloc[ \t]*$'
    )
    section_piggy_fixed = re.compile(
        r'(?m)^[ \t]*\.section[ \t]+"?\.piggydata"?'
        r'[ \t]*,[ \t]*"a"[ \t]*$'
    )

    changes: list[str] = []

    count = rewrite_section(
        root / "arch/arm/boot/compressed/head.S",
        section_start_legacy,
        section_start_fixed,
        r'\g<indent>.section ".start", "ax"',
        "compressed ARM startup",
    )
    changes.append(f"compressed-head={count}")

    count = rewrite_section(
        root / "arch/arm/mm/proc-v7.S",
        section_proc_legacy,
        section_proc_fixed,
        r'\g<indent>.section ".proc.info.init", "a"',
        "ARMv7 proc info",
    )
    changes.append(f"proc-v7={count}")

    piggy_sources = sorted((root / "arch/arm/boot/compressed").glob("piggy.*.S"))
    if not piggy_sources:
        raise RewriteError("no ARM compressed piggy assembly sources were found")
    piggy_changes = 0
    for piggy_path in piggy_sources:
        piggy_changes += rewrite_section(
            piggy_path,
            section_piggy_legacy,
            section_piggy_fixed,
            r'\g<indent>.section .piggydata, "a"',
            f"ARM compressed payload ({piggy_path.name})",
        )
    changes.append(f"piggy-sources={piggy_changes}")

    for relative in (
        "drivers/net/wireless/rockchip_wlan/ssv6xxx/smac/dev.c",
        "drivers/net/wireless/ssv6x5x/smac/dev.c",
    ):
        count = rewrite_ssv(root / relative)
        changes.append(f"{relative}={count}")

    print("RK322x legacy post-patch compatibility: " + ", ".join(changes))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"rk322x-legacy-postpatch.py: {exc}", file=sys.stderr)
        raise SystemExit(1)
