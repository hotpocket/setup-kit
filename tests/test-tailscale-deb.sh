#!/bin/bash
# Calibration: a tailscale already installed from the deb (pkgs.tailscale.com)
# is not given a second copy from snap. snap.list lists tailscale "always"; two
# tailscaleds fight over tailscale0 and drop the node off the tailnet — on a
# box set up over the tailnet, mid-install, that is the session running it.
#
# Contract (stubbed snap/dpkg-query/sudo, no network):
#   A. deb installed, no snap: 03 reports it from apt and installs no snap
#   B. no deb, no snap: 03 still installs the snap (the owner's default)
#   C. verify.sh, deb installed: passes tailscale, no snap failure
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -i tailscale "$TMP/out" "$TMP/calls" | sed 's/^/       | /'; fi; }
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
# snap: nothing installed; every call recorded
printf '#!/bin/bash\necho "snap $*" >> "%s/calls"\n[[ "$1" == list ]] && exit 1\nexit 0\n' "$TMP" > "$BIN/snap"
printf '#!/bin/bash\n"$@"\n' > "$BIN/sudo"
# dpkg-query: tailscale installed iff $TMP/deb exists
printf '#!/bin/bash\n[[ "${*: -1}" == tailscale && -e "%s/deb" ]] && { echo "install ok installed"; exit 0; }\nexit 1\n' "$TMP" > "$BIN/dpkg-query"
printf '#!/bin/bash\nexit 0\n' > "$BIN/flatpak"
chmod +x "$BIN"/*
printf 'group_apps=no\n' > "$TMP/host.conf"
run03() { : > "$TMP/calls"; PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/03-snap-flatpak.sh" install >"$TMP/out" 2>&1; }

touch "$TMP/deb"; run03
assert "A. deb installed: reported from apt, no snap install" \
  'grep -q "OK.*tailscale.*apt" "$TMP/out" && ! grep -q "snap install tailscale" "$TMP/calls"'
rm -f "$TMP/deb"; run03
assert "B. no deb: the snap is still installed" 'grep -q "snap install tailscale" "$TMP/calls"'
touch "$TMP/deb"
( cd "$KIT_DIR" && PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1
assert "C. verify, deb installed: tailscale passes, no snap failure" \
  'grep -q "PASS.*tailscale" "$TMP/out" && ! grep -q "FAIL.*snap: tailscale" "$TMP/out"'

echo "test-tailscale-deb: $pass passed, $fail failed"
(( fail == 0 ))
