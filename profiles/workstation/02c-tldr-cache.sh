#!/bin/bash
# Seed tealdeer's tldr page cache. The 'tealdeer' package (cli-system) ships
# NO offline pages — a fresh `tldr <cmd>` errors "Page cache not found" until
# `tldr --update` downloads them. Runs after 02-apt-install put tealdeer on the
# box. Cache lives under ~/.cache/tealdeer (regenerable, not a dotfile), so this
# is provisioning, not user config — `tldr --list` is the read-only probe.
SCRIPT_NAME="ws-02c-tldr-cache"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

command -v tldr >/dev/null 2>&1 || exit 0   # tealdeer not installed (skipped / group off)

section "tldr page cache ($MODE)"

# --list exits non-zero (and prints the "Page cache not found" hint) when the
# cache is empty; it's the cheapest "is the cache seeded?" probe tealdeer offers.
if tldr --quiet --list >/dev/null 2>&1; then
  ok "tldr page cache present"
  exit 0
fi

warn "tldr page cache missing — tldr <cmd> will error until updated"
if (( ! INSTALL )); then
  miss "tldr: page cache empty — run 'tldr --update' (needs network)"
  exit 0
fi

# install: pull the pages. Network-dependent; a failure is logged, not fatal —
# the kit converges over re-runs and a missing cache never blocks the box.
if do_or_say tldr --update; then
  ok "tldr page cache seeded"
else
  warn "tldr --update failed (offline?) — cache still empty"
  miss "tldr: 'tldr --update' failed — re-run when online"
fi
