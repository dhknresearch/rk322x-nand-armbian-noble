#!/usr/bin/env python3
"""Tune the restored RK322x Linux 4.4 config for modern userspace.

The config changes are deliberately limited to:
* disabling the incompatible vendor rtl8812au driver;
* enabling the kernel primitives systemd 257/udev document as required;
* disabling legacy sysfs/firmware-helper modes that conflict with udev.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


RTL8812_PATTERNS = (
    re.compile(r"^(?:88XXAU)(?:_[A-Z0-9_]+)?$"),
    re.compile(r"^(?:RTL)?8812AU(?:_[A-Z0-9_]+)?$"),
    re.compile(r"^RTL8812_AU(?:_[A-Z0-9_]+)?$"),
)
RTL8812_REQUIRED_UNSETS = ("88XXAU", "RTL8812AU")

# systemd 257's documented hard requirements and the namespace features used by
# common system services. Linux 4.4 contains all of these symbols on ARM.
REQUIRED_VALUES: dict[str, str] = {
    "DEVTMPFS": "y",
    "DEVTMPFS_MOUNT": "y",
    "CGROUPS": "y",
    "INOTIFY_USER": "y",
    "SIGNALFD": "y",
    "TIMERFD": "y",
    "EPOLL": "y",
    "UNIX": "y",
    "SYSFS": "y",
    "PROC_FS": "y",
    "FHANDLE": "y",
    "NAMESPACES": "y",
    "UTS_NS": "y",
    "IPC_NS": "y",
    "USER_NS": "y",
    "PID_NS": "y",
    "NET_NS": "y",
    "SECCOMP": "y",
    "SECCOMP_FILTER": "y",
    "UEVENT_HELPER_PATH": '""',
}
REQUIRED_UNSETS = (
    "SYSFS_DEPRECATED",
    "FW_LOADER_USER_HELPER",
    "FW_LOADER_USER_HELPER_FALLBACK",
    "RT_GROUP_SCHED",
)


def assignment_symbol(line: str) -> str | None:
    match = re.fullmatch(r"CONFIG_([A-Z0-9_]+)=.*", line)
    return match.group(1) if match else None


def unset_symbol(line: str) -> str | None:
    match = re.fullmatch(r"# CONFIG_([A-Z0-9_]+) is not set", line)
    return match.group(1) if match else None


def is_incompatible_rtl8812(symbol: str) -> bool:
    return any(pattern.fullmatch(symbol) for pattern in RTL8812_PATTERNS)


def replace_symbols(lines: list[str], values: dict[str, str], unsets: set[str]) -> list[str]:
    targeted = set(values) | unsets
    output: list[str] = []
    for line in lines:
        symbol = assignment_symbol(line) or unset_symbol(line)
        if symbol in targeted:
            continue
        output.append(line)

    output.extend(f"CONFIG_{symbol}={value}" for symbol, value in values.items())
    output.extend(f"# CONFIG_{symbol} is not set" for symbol in sorted(unsets))
    return output


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/linux-rk322x-legacy.config", file=sys.stderr)
        return 64

    path = Path(sys.argv[1])
    if not path.is_file():
        raise FileNotFoundError(path)

    lines = path.read_text().splitlines()
    rtl_disabled: list[str] = []
    filtered: list[str] = []

    for line in lines:
        symbol = assignment_symbol(line)
        if symbol is not None and is_incompatible_rtl8812(symbol):
            filtered.append(f"# CONFIG_{symbol} is not set")
            rtl_disabled.append(symbol)
        else:
            filtered.append(line)

    rtl_unsets = set(RTL8812_REQUIRED_UNSETS)
    for symbol in RTL8812_REQUIRED_UNSETS:
        if f"# CONFIG_{symbol} is not set" not in filtered:
            rtl_disabled.append(symbol)

    output = replace_symbols(filtered, REQUIRED_VALUES, set(REQUIRED_UNSETS))
    # replace_symbols removed the rtl aliases if they overlap targeted symbols;
    # append and deduplicate their explicit unsets after all generic changes.
    output = [
        line
        for line in output
        if not (
            (symbol := assignment_symbol(line) or unset_symbol(line))
            and is_incompatible_rtl8812(symbol)
        )
    ]
    output.extend(f"# CONFIG_{symbol} is not set" for symbol in sorted(rtl_unsets))

    active_rtl = [
        line
        for line in output
        if (symbol := assignment_symbol(line)) is not None
        and is_incompatible_rtl8812(symbol)
    ]
    if active_rtl:
        raise RuntimeError("incompatible rtl8812au symbols remain active: " + ", ".join(active_rtl))

    path.write_text("\n".join(output) + "\n")
    print(
        "Disabled incompatible optional kernel module symbol(s): "
        + ", ".join(dict.fromkeys(rtl_disabled))
    )
    print(
        "Enabled Linux-4.4 userspace compatibility symbols: "
        + ", ".join(REQUIRED_VALUES)
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"tune_kernel_config.py: {exc}", file=sys.stderr)
        raise SystemExit(1)
