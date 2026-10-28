#!/usr/bin/env python3
"""kit-heavy COMMAND: one bounded, niced build/browser job at a time.

The transient service owns the tree. A pidfd binds it to its calling tool,
so SIGKILL of that tool cannot leave work or an inherited lock behind.
"""
import fcntl
import os
import select
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path


def guard(owner, lock, command):
    owners = [int(pid) for pid in str(owner).split(',')]
    owner_fds = []
    try:
        for pid in owners:
            owner_fds.append(os.pidfd_open(pid))
    except ProcessLookupError:
        for fd in owner_fds:
            os.close(fd)
        return 125
    child = None
    handle = None
    stopped = False

    def cancel(_signum, _frame):
        nonlocal stopped
        stopped = True

    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}

    def abandoned():
        if stopped or select.select(owner_fds, [], [], 0)[0]:
            return True
        # A suspended terminal job must not hold the shared queue forever.
        try:
            return any(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] in ("T", "t") for pid in owners)
        except OSError:
            return True

    try:
        Path(lock).parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock, "a")  # CLOEXEC; held until tree cleanup finishes
        while True:
            if abandoned():
                return 125
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(.1)
        if abandoned():
            return 125
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        while child.poll() is None:
            if abandoned():
                return 125
            time.sleep(.1)
        return child.returncode
    finally:
        # The systemd KillMode is the backstop for escaped groups or a killed
        # supervisor. Also clean the ordinary group in standalone calibration.
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        if handle is not None:
            handle.close()
        for fd in owner_fds:
            os.close(fd)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def launch_command(command, unit, lock, ram_mb):
    return [
        "systemd-run", "--user", "--collect", "--wait", "--pipe", "--quiet",
        "--service-type=exec", f"--unit={unit}",
        f"--working-directory={os.getcwd()}", f"--setenv=PATH={os.environ.get('PATH', '/usr/bin:/bin')}",
        "--property=OOMPolicy=kill", "--property=KillMode=control-group",
        "--property=OOMScoreAdjust=800", "--property=Nice=10",
        "--property=CPUWeight=20", "--property=IOWeight=20",
        f"--property=MemoryHigh={ram_mb * 5 // 8}M",
        f"--property=MemoryMax={ram_mb * 3 // 4}M",
        "--", sys.executable, str(Path(__file__).resolve()),
        "--guard", f"{os.getpid()},{os.getppid()}", lock, *command,
    ]


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "--guard":
        return guard(sys.argv[2], sys.argv[3], sys.argv[4:])
    if len(sys.argv) < 2:
        print("usage: kit-heavy COMMAND [ARG ...]", file=sys.stderr)
        return 2
    ram_mb = int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines() if line.startswith("MemTotal:"))) // 1024
    lock = str(Path.home() / ".cache/setup-kit-heavy.lock")
    unit = "setup-kit-heavy-" + uuid.uuid4().hex
    try:
        return subprocess.call(launch_command(sys.argv[1:], unit, lock, ram_mb), stdin=subprocess.DEVNULL)
    finally:
        subprocess.run(["systemctl", "--user", "stop", unit + ".service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    sys.exit(main())
