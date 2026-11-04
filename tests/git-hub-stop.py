"""Kill a fixture relay after delivery starts, before its completion marker."""
import os
from pathlib import Path
import signal
import subprocess
import time

p = subprocess.Popen(["bash", os.environ["KIT_DIR"] + "/components/git-hub/git-hub", "relay"],
                     start_new_session=True)
marker = Path(os.environ["TMP"]) / "send-started"
deadline = time.monotonic() + 12
ready = False
try:
    while time.monotonic() < deadline:
        if marker.exists():
            ready = True
            break
        if p.poll() is not None:
            break
        time.sleep(0.02)
finally:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait()
raise SystemExit(0 if ready else 1)
