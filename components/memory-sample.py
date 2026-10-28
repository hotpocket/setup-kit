#!/usr/bin/env python3
"""Bounded, CPU-only counterpart of ai-3090's mem-log: size from peaks.

Private daily CSVs, 30 days retained. A sample never signals or changes a
process; racing exits and inaccessible processes are expected.
"""
import csv
import datetime
import os
import re
from pathlib import Path


def kb(text, key):
    match = re.search(rf"^{key}:\s+(\d+)", text, re.M)
    return int(match[1]) if match else 0


def main():
    proc = Path(os.environ.get("KIT_MEMORY_PROC", "/proc"))
    out = Path.home() / ".local/state/setup-kit-memory"
    mem = (proc / "meminfo").read_text()
    swaps = {"zram": 0, "disk": 0}
    for line in (proc / "swaps").read_text().splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 4:
            swaps["zram" if "zram" in fields[0] else "disk"] += int(fields[3])
    kinds = {"agent": [0, 0], "browser": [0, 0]}
    for process in proc.iterdir():
        if not process.name.isdigit():
            continue
        try:
            cmd = (process / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            status = (process / "status").read_text()
        except OSError:
            continue
        kind = "agent" if re.search(r"\b(claude|codex)\b", cmd) else "browser" if re.search(r"\b(chrome|chromium|firefox|webkit)\b", cmd) else None
        if kind:
            kinds[kind][0] += 1
            kinds[kind][1] += kb(status, "VmRSS") + kb(status, "VmSwap")
    row = {
        "time": datetime.datetime.now().isoformat(timespec="seconds"),
        "mem_available_mb": kb(mem, "MemAvailable") // 1024,
        "zram_used_mb": swaps["zram"] // 1024,
        "disk_used_mb": swaps["disk"] // 1024,
        "agent_count": kinds["agent"][0],
        "agent_mb": kinds["agent"][1] // 1024,
        "browser_count": kinds["browser"][0],
        "browser_mb": kinds["browser"][1] // 1024,
    }
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    today = datetime.date.today()
    for path in out.glob("*.csv"):
        # Delete only our dated history, never arbitrary files in this dir.
        try:
            date = datetime.date.fromisoformat(path.stem)
        except ValueError:
            continue
        if (today - date).days >= 30:
            path.unlink()
    path = out / f"{today}.csv"
    # One invocation per minute by a oneshot timer; a crash can lose a row.
    with path.open("a") as handle:
        writer = csv.DictWriter(handle, fieldnames=row)
        if handle.tell() == 0:
            writer.writeheader()
        writer.writerow(row)


if __name__ == "__main__":
    main()
