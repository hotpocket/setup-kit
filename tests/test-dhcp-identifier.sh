#!/bin/bash
# Every cloud VM whose NIC is renamed after first DHCP gets two leases.
# Exercise phase 03 and the independent verifier using fake roots and commands.
set -uo pipefail
KIT_DIR="${DHCP_TEST_KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
K="$TMP/kit"; BIN="$TMP/bin"
mkdir -p "$K" "$BIN"
cp -a "$KIT_DIR"/{lib.sh,profiles,components,manifests,verify.sh} "$K/"
export FIXTURE="$TMP" CALLS="$TMP/calls" HOME="$TMP/home" USER=fixture
export KIT_NETPLAN_ROOT="$TMP/root" HOST_CONF="$TMP/host.conf" KIT_HOST_CONF="$TMP/host.conf"
export KIT_LOG_DIR="$TMP/logs" KIT_VERBOSE=1 PATH="$BIN:/usr/bin:/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
FILE="$KIT_NETPLAN_ROOT/etc/netplan/90-dhcp-mac.yaml"
CANON='network: {version: 2, ethernets: {eth0: {dhcp-identifier: mac}}}'
cat > "$BIN/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >> "$CALLS"
[[ "${1:-}" != -n ]] || exit 1
case "$1" in
  /usr/bin/python3)
    [[ "$2" == "$FIXTURE/kit/profiles/worker/"* && "$3" == "$KIT_NETPLAN_ROOT" ]] || exit 99 ;;
  stat|cat|cmp|mkdir|mktemp|tee|chmod|chown|cp|mv|rm)
    for a in "${@:2}"; do
      case "$a" in /*) [[ "$a" == "$KIT_NETPLAN_ROOT/"* ]] || exit 99 ;; esac
    done ;;
  netplan) ;;
  *) echo "blocked sudo: $*" >&2; exit 99 ;;
esac
exec "$@"
SH
cat > "$BIN/netplan" <<'PY'
#!/usr/bin/python3
import os, pathlib, sys, yaml
root = pathlib.Path(os.environ['KIT_NETPLAN_ROOT'])
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log:
    log.write('netplan ' + ' '.join(args) + '\n')
if args[0] == 'get':
    if (root / 'get-fail').exists():
        sys.exit(2)
    # The CLI gives a merged view; this independent fixture can differ from
    # the disk YAML to prove the installer prefers netplan get.
    p = root / 'get.yaml'
    if not p.exists():
        p = root / 'etc/netplan/50-cloud-init.yaml'
    data = yaml.safe_load(p.read_text())
    print(yaml.safe_dump(data['network']['ethernets'], sort_keys=False), end='')
elif args[0] == 'generate':
    f = root / 'etc/netplan/90-dhcp-mac.yaml'
    if not f.exists() or f.read_text() != (root / 'expected').read_text():
        sys.exit('generate did not see the complete replacement')
    if f.stat().st_mode & 0o777 != 0o600:
        sys.exit('generate saw unsafe permissions')
    (root / 'generated').touch()
    if (root / 'generate-fail').exists():
        sys.exit('fixture: generate rejected candidate')
else:
    sys.exit('blocked netplan action')
PY
# These two model root ownership without granting this test root privileges.
cat > "$BIN/chown" <<'SH'
#!/bin/bash
echo "chown $*" >> "$CALLS"
[[ "$1" == root:root && "$2" == "$KIT_NETPLAN_ROOT/"* ]] || exit 99
SH
cat > "$BIN/stat" <<'SH'
#!/bin/bash
if [[ "$*" == *%u* || "$*" == *%g* ]]; then
  [[ -f "${@: -1}" ]] || exit 1
  mode=$(/usr/bin/stat -c %a "${@: -1}")
  printf '%s:%s\n' "$mode" "$(if [[ -f "$KIT_NETPLAN_ROOT/wrong-owner" ]]; then echo 1000:1000; else echo 0:0; fi)"
else exec /usr/bin/stat "$@"; fi
SH
cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$*" in get-default) echo multi-user.target ;; *graphical.target*) exit 1 ;; esac
exit 0
SH
printf '#!/bin/bash\necho "loginctl $*" >> "$CALLS"\necho yes\n' > "$BIN/loginctl"
printf '#!/bin/bash\necho fixture-host\n' > "$BIN/hostname"
printf '#!/bin/bash\necho "{\"BackendState\":\"NeedsLogin\"}"\n' > "$BIN/tailscale"
for c in lspci journalctl coredumpctl gsettings git curl wget aws ssh gh dpkg-query dpkg systemd-detect-virt; do
  printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"
done
chmod +x "$BIN"/*
reset() {
  rm -rf "$KIT_NETPLAN_ROOT" "$HOME" "$KIT_LOG_DIR"
  mkdir -p "$KIT_NETPLAN_ROOT/etc/netplan" "$HOME/.ssh"
  echo 'ssh-ed25519 fixture' > "$HOME/.ssh/authorized_keys"
  cat > "$KIT_NETPLAN_ROOT/etc/netplan/50-cloud-init.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    eth0:
      match: {macaddress: '02:00:00:00:00:01'}
      set-name: eth0
      dhcp4: true
YAML
  printf '%s\n' profile=worker headless=yes configs=no git_auth=none aws_profile=none \
    cond_nvidia=no component_resource_guards=no component_oom_zram=no tmp_on_disk=no \
    component_dictation=no component_clipboard=no lang_python=no lang_node=no > "$HOST_CONF"
  printf '%s\n' "$CANON" > "$KIT_NETPLAN_ROOT/expected"
  : > "$CALLS"
}
enabled() { echo 'net_dhcp_identifier=mac' >> "$HOST_CONF"; }
phase() { bash "$K/profiles/worker/03-headless.sh" "${1:-check}" > "$TMP/out" 2>&1; RC=$?; }
verify() { bash "$K/verify.sh" > "$TMP/out" 2>&1; RC=$?; }
handmade() { printf '%s\n' "$CANON" > "$FILE"; chmod "${1:-600}" "$FILE"; }
unchanged() { [[ "$(/usr/bin/stat -c '%i:%s:%Y:%Z:%a' "$FILE")" == "$BEFORE" ]]; }
snapshot() { BEFORE=$(/usr/bin/stat -c '%i:%s:%Y:%Z:%a' "$FILE"); }
no_mutations() { ! grep -qE '^netplan (generate|apply|try)|^sudo (mkdir|mktemp|tee|chmod|chown|cp|mv|rm) ' "$CALLS"; }
assert() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; cat "$TMP/out"; return 1; fi; }
case_unset() {
  phase install
  assert 'unset: no DHCP calls or file' '[[ ! -e "$FILE" ]] && ! grep -qE "netplan|^sudo " "$CALLS"'
}
case_check() {
  enabled; phase check
  assert 'check: missing reported without writes' 'grep -q "WARN.*DHCP identifier.*missing" "$TMP/out" && [[ ! -e "$FILE" ]] && no_mutations'
}
case_content() {
  enabled; phase install
  assert 'install: exact complete content validated in fake root' 'cmp -s "$FILE" "$KIT_NETPLAN_ROOT/expected" && [[ -f "$KIT_NETPLAN_ROOT/generated" ]] && grep -q "^netplan get ethernets --root-dir $KIT_NETPLAN_ROOT$" "$CALLS"'
}
case_mode() {
  enabled; handmade 644; phase install
  assert 'install: repairs mode and sets root ownership' '[[ "$(/usr/bin/stat -c %a "$FILE")" == 600 ]] && grep -q "^chown root:root $KIT_NETPLAN_ROOT/etc/netplan/" "$CALLS"'
}
case_rerun() {
  enabled; phase install; snapshot; : > "$CALLS"; phase install
  assert 'second install: ok, no mutation' 'grep -q "OK.*DHCP identifier.*matches" "$TMP/out" && unchanged && no_mutations'
}
case_handmade() {
  enabled; handmade; snapshot; phase install
  assert '105 hand-made file: accepted byte-for-byte without replacement' 'grep -q "OK.*DHCP identifier.*matches" "$TMP/out" && unchanged && no_mutations'
}
case_rollback() {
  enabled; echo 'network: {version: 2, ethernets: {eth0: {dhcp-identifier: duid}}}' > "$FILE"
  chmod 640 "$FILE"; cp -p "$FILE" "$TMP/previous"; touch "$KIT_NETPLAN_ROOT/generate-fail"; phase install
  assert 'invalid generate: previous bytes and mode restored, failure reported' '(( RC != 0 )) && [[ -f "$KIT_NETPLAN_ROOT/generated" ]] && cmp -s "$FILE" "$TMP/previous" && [[ "$(/usr/bin/stat -c %a "$FILE")" == 640 ]] && grep -q "FAIL.*restored" "$TMP/out" && [[ "$(find "${FILE%/*}" -type f | wc -l)" == 2 ]]'
}
case_rollback_absent() {
  enabled; touch "$KIT_NETPLAN_ROOT/generate-fail"; phase install
  assert 'invalid generate: absent file stays absent' '(( RC != 0 )) && [[ -f "$KIT_NETPLAN_ROOT/generated" && ! -e "$FILE" ]] && grep -q "FAIL.*restored" "$TMP/out"'
}
multiple() {
  cat > "$KIT_NETPLAN_ROOT/get.yaml" <<'YAML'
network:
  ethernets:
    uplink: {match: {macaddress: '02:00:00:00:00:02'}, set-name: eth1, dhcp4: true}
    eth0: {dhcp4: true}
    static0: {dhcp4: false, addresses: [192.0.2.1/24]}
    v6only: {dhcp6: true}
  wifis: {wifi0: {dhcp4: true}}
YAML
  printf '%s\n' 'network: {version: 2, ethernets: {eth0: {dhcp-identifier: mac}, uplink: {dhcp-identifier: mac}, v6only: {dhcp-identifier: mac}}}' > "$KIT_NETPLAN_ROOT/expected"
}
case_multiple() {
  enabled; multiple; phase install
  assert 'multiple: every DHCP ethernet config ID covered, static and wifi omitted' 'cmp -s "$FILE" "$KIT_NETPLAN_ROOT/expected" && [[ -f "$KIT_NETPLAN_ROOT/generated" ]]'
}
case_fallback() {
  enabled; touch "$KIT_NETPLAN_ROOT/get-fail"
  mkdir -p "$KIT_NETPLAN_ROOT/"{lib,run}/netplan
  echo 'network: {ethernets: {other: {dhcp4: true}, eth0: {dhcp4: true}}}' > "$KIT_NETPLAN_ROOT/lib/netplan/10-vendor.yaml"
  echo 'network: {ethernets: {other: {dhcp4: false}}}' > "$KIT_NETPLAN_ROOT/etc/netplan/20-local.yaml"
  echo 'network: {ethernets: {eth0: {dhcp4: false}}}' > "$KIT_NETPLAN_ROOT/lib/netplan/50-cloud-init.yaml"
  phase install
  assert 'fallback: YAML hierarchy merge and same-name shadowing preserve DHCP eth0' 'cmp -s "$FILE" "$KIT_NETPLAN_ROOT/expected" && [[ -f "$KIT_NETPLAN_ROOT/generated" ]]'
}
case_read_error() {
  enabled; touch "$KIT_NETPLAN_ROOT/get-fail"
  echo 'network: [' > "$KIT_NETPLAN_ROOT/etc/netplan/50-cloud-init.yaml"; phase install
  assert 'unreadable config: failure without writing' '(( RC != 0 )) && grep -q "FAIL.*DHCP identifier" "$TMP/out" && [[ ! -e "$FILE" ]] && no_mutations'
}
case_next_boot() {
  enabled; phase install
  assert 'install: names deferred activation, never applies or tries' 'grep -q "next reboot or DHCP renewal" "$TMP/out" && ! grep -qE "^netplan (apply|try)" "$CALLS"'
}
case_verify_missing() {
  enabled; verify
  assert 'verify: reports DHCP file missing without mutations' 'grep -q "FAIL.*DHCP identifier" "$TMP/out" && [[ ! -e "$FILE" ]] && no_mutations'
}
case_verify_handmade() {
  enabled; handmade; snapshot; verify
  assert 'verify: accepts 105 file unchanged' 'grep -q "PASS.*DHCP identifier" "$TMP/out" && unchanged && no_mutations'
}
case_verify_mode() {
  enabled; handmade 644; verify
  assert 'verify: reports unsafe mode without repairing' 'grep -q "FAIL.*DHCP identifier" "$TMP/out" && [[ "$(/usr/bin/stat -c %a "$FILE")" == 644 ]] && no_mutations'
}
case_verify_owner() {
  enabled; handmade; touch "$KIT_NETPLAN_ROOT/wrong-owner"; verify
  assert 'verify: reports wrong ownership' 'grep -q "FAIL.*DHCP identifier" "$TMP/out" && no_mutations'
}
case_verify_multiple() {
  enabled; multiple; handmade; verify
  assert 'verify: detects uncovered DHCP config ID' 'grep -q "FAIL.*DHCP identifier" "$TMP/out" && no_mutations'
}
case_verify_unset() {
  verify
  assert 'verify unset: no DHCP checks or netplan calls' '! grep -q "DHCP identifier" "$TMP/out" && ! grep -q "netplan" "$CALLS"'
}
pass=0; fail=0
for name in unset check content mode rerun handmade rollback rollback_absent multiple fallback read_error next_boot verify_missing verify_handmade verify_mode verify_owner verify_multiple verify_unset; do
  [[ -z "${1:-}" || "$name" == "$1" ]] || continue
  reset
  if "case_$name"; then ((pass++)); else ((fail++)); fi
done
echo "test-dhcp-identifier: $pass passed, $fail failed"
(( fail == 0 ))
