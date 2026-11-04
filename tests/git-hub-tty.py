"""Exercise token-set through a PTY, sending input only after echo is disabled."""
import errno
import os
import pty
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
p = subprocess.Popen(["bash", os.environ["KIT_DIR"] + "/components/git-hub/git-hub", "token-set"],
                     stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
out = b""
sent = set()
deadline = time.monotonic() + 12
while time.monotonic() < deadline:
    if select.select([master], [], [], 0.1)[0]:
        try:
            chunk = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        out += chunk
    for marker, value in [(b"Token: ", sys.argv[1]), (b"Expiry date (YYYY-MM-DD): ", sys.argv[2])]:
        if marker in out and marker not in sent:
            os.write(master, value.encode() + b"\n")
            sent.add(marker)
else:
    p.kill()
    out += b"TTY test timed out\n"
p.wait()
os.close(master)
sys.stdout.buffer.write(out)
sys.exit(p.returncode)
