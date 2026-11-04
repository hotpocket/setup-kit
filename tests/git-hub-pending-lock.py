"""Check the real pending command under contention without leaving a waiter."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

command = ["bash", os.environ["KIT_DIR"] + "/components/git-hub/git-hub", "gate"]
env = dict(os.environ, SSH_ORIGINAL_COMMAND="pending")
expected = "=== books " + sys.argv[1] + " "


def pending():
    p = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    started = time.monotonic()
    try:
        out, err = p.communicate(timeout=25)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        raise AssertionError("pending exceeded its short lock bound") from None
    return p.returncode, out, err, time.monotonic() - started


code, out, _, _ = pending()
assert code == 0 and expected in out, "calibration: request absent before lock"
lock = Path(os.environ["HOME"]) / ".local/state/git-hub/release.lock"
with lock.open("a") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    code, out, err, elapsed = pending()
    assert code == 0 and not out and not err and elapsed < 25, \
        "contended pending must exit successfully and silently within its bound"
code, out, _, _ = pending()
assert code == 0 and expected in out, "request lost while pending was contended"
print("pending lock bound: observed request before/after; busy response empty")
