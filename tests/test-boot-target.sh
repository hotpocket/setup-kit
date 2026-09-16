#!/bin/bash
# Calibration for the worker's boot target (03-headless §1). It used to be
# hardwired to multi-user.target: a box whose owner wanted the Proxmox console
# to show GNOME got it switched off at the next install and had no knob to say
# otherwise (2026-09-16, ai-3090). Now the host conf's boot_target decides;
# multi-user stays the worker default.
#
# Contract (check mode, stubbed systemctl, no sudo):
#   A. boot_target unset + machine on graphical: warns, wants multi-user
#   B. boot_target=graphical + machine on graphical: ok, wants nothing
#   C. boot_target=graphical + machine on multi-user: warns, wants graphical
#   D. boot_target=nonsense: refused by name, no set-default proposed
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/systemctl" <<'S'
#!/bin/bash
case "$1" in get-default) cat "$STUB_TARGET" ;; is-active|is-enabled) exit 1 ;; *) exit 0 ;; esac
S
chmod +x "$TMP/bin/systemctl"
run() {  # <conf-body> <current-target>
  printf '%b\n' "$1" > "$TMP/host.conf"; echo "$2" > "$TMP/target"
  PATH="$TMP/bin:$PATH" STUB_TARGET="$TMP/target" HOME="$TMP/home" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/worker/03-headless.sh" check 2>&1 | sed -n '/headless boot/,/ssh in/p' > "$TMP/out"
}
run 'profile=worker' graphical.target
assert "A. default wants multi-user on a graphical box" \
  'grep -q "desktop starts at boot" "$TMP/out" && grep -q "set-default multi-user.target" "$TMP/out"'
run 'profile=worker\nboot_target=graphical' graphical.target
assert "B. boot_target=graphical on a graphical box: ok, no change" \
  'grep -q "default target graphical.target" "$TMP/out" && ! grep -q "set-default" "$TMP/out"'
run 'profile=worker\nboot_target=graphical' multi-user.target
assert "C. boot_target=graphical on a multi-user box: wants graphical" \
  'grep -q "set-default graphical.target" "$TMP/out"'
run 'profile=worker\nboot_target=nonsense' multi-user.target
assert "D. unknown boot_target refused by name" \
  'grep -q "boot_target=nonsense" "$TMP/out" && ! grep -q "set-default" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
