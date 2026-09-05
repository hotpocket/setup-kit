# setup-kit — TODOs

Open work for the setup-kit repo.

(none — 2026-09-05: the fresh-install verification happened on Beast-VM, and
the `grep -q`-under-pipefail audit closed: only a producer that writes more
than the 64 KiB pipe buffer after grep's first match can flake; `find` in
verify.sh was the last such producer and now uses `-print -quit`.)
