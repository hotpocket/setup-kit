#!/bin/bash
# Muse calibration: fake HOME, stub curl, no network or real provisioning.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skip=0
H="$TMP/home"; BIN="$TMP/bin"; STATE="$TMP/state"
M="$H/.config/muse/settings.json"; T="$H/.t3/userdata/settings.json"
mkdir -p "$BIN" "$STATE"
cat > "$TMP/launcher" <<'S'
#!/usr/bin/env bash
launcher_url="https://api.meta.ai/muse-launcher.sh"
echo 'muse executed' >> "$STATE/calls"
exit 99
S
cat > "$BIN/curl" <<'S'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$STATE/calls"
dest=
while (( $# )); do
  case "$1" in -o|--output) dest=$2; shift ;; esac
  shift
done
[[ -n "$dest" && "$dest" == "$HOME/.local/bin/"* && "$dest" != "$HOME/.local/bin/muse" ]] || exit 98
case "${DOWNLOAD:-good}" in
  good) cp "$STATE/launcher" "$dest" ;;
  html) printf '<html>error</html>\n' > "$dest" ;;
  shebang) printf '#!/bin/sh\nlauncher_url="https://api.meta.ai/muse-launcher.sh"\n' > "$dest" ;;
  url) printf '#!/usr/bin/env bash\nlauncher_url="https://example.invalid/muse"\n' > "$dest" ;;
  failed) cp "$STATE/launcher" "$dest"; exit 22 ;;
esac
S
# Kernel watch calibrated by deliberately reading a fixture before the phase.
# The real phase must neither open nor read auth.json, even through Python.
cat > "$TMP/watch.py" <<'PY'
import ctypes, os, struct, subprocess, sys
path, report, *command = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
assert fd >= 0
assert libc.inotify_add_watch(fd, os.fsencode(path), 0x21) >= 0  # ACCESS | OPEN
subprocess.run(['/bin/cat', path], stdout=subprocess.DEVNULL, check=True)
def events():
    try:
        raw = os.read(fd, 65536)
    except BlockingIOError:
        return []
    masks = []
    offset = 0
    while offset < len(raw):
        _, mask, _, size = struct.unpack_from('iIII', raw, offset)
        masks.append(mask)
        offset += 16 + size
    return masks
assert any(mask & 0x21 for mask in events()), 'auth read detector did not calibrate'
result = subprocess.run(command)
with open(report, 'w') as out:
    out.write('calibrated\n')
    for mask in events():
        if mask & 0x21:
            out.write('auth opened or read\n')
os.close(fd)
sys.exit(result.returncode)
PY
chmod +x "$BIN/curl"
cp "$TMP/launcher" "$STATE/launcher"
reset() {
  rm -rf "$H"; mkdir -p "$H"
  : > "$STATE/calls"; : > "$TMP/out"; rm -f "$TMP/missing.log"
  DOWNLOAD=good; WATCH_AUTH=0
  conf component_muse=yes
}
conf() {
  printf '%s\n' tmp_on_disk=no component_resource_guards=no component_oom_zram=no \
    component_docker_rootless=skip component_herdr=no component_uutils_ls=no component_ollama=no \
    component_t3code=no component_codex=no component_git_hub=no group_dev_cloud=no \
    component_whisper=no component_chatterbox=no component_mtga=no component_dictation=no \
    component_ocr=no component_tts=no component_clipboard=no component_lid_ignore=no \
    component_emudhra=no "$@" > "$TMP/host.conf"
}
run07() {
  local mode=${1:-check}
  local -a command=(bash "$KIT_DIR/profiles/workstation/07-components.sh" "$mode")
  if (( WATCH_AUTH )); then
    command=(python3 -I "$TMP/watch.py" "$H/.config/muse/auth.json" "$TMP/auth-watch" "${command[@]}")
  fi
  PATH="$BIN:/usr/bin:/bin" HOME="$H" STATE="$STATE" DOWNLOAD="$DOWNLOAD" HOST_CONF="$TMP/host.conf" \
    KIT_LOG_DIR="$TMP" KIT_QUIET=0 "${command[@]}" > "$TMP/out" 2>&1
}
ready() { mkdir -p "$H/.local/bin"; cp "$TMP/launcher" "$H/.local/bin/muse"; chmod 755 "$H/.local/bin/muse"; }
settings() { local value='{"schema_version":1,"contributor_mode_enabled":false}'; mkdir -p "$(dirname "$M")"; printf '%s\n' "${1:-$value}" > "$M"; }
t3() { mkdir -p "$(dirname "$T")"; printf '%s\n' "$1" > "$T"; }
snapshot() {
  # Content, names, permissions, inode, mtime and ctime. Ignore atime from reads.
  python3 -I - "$H" <<'PY'
import hashlib, pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    s = p.lstat()
    print(p.relative_to(sys.argv[1]), s.st_mode, s.st_ino, s.st_mtime_ns, s.st_ctime_ns,
          hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else '-')
PY
}
json_is() { python3 -I -c 'import json,sys; assert json.dumps(json.load(open(sys.argv[1])), sort_keys=True) == json.dumps(json.loads(sys.argv[2]), sort_keys=True)' "$1" "$2"; }
contains() { grep -Fq -- "$1" "$TMP/out"; }
clean_stage() { [[ -z "$(find "$H" -name '*.tmp*' -o -name '.muse.*')" ]]; }
check() {
  if [[ -n "${MUSE_CASE:-}" && "$MUSE_CASE" != "$1" ]]; then return; fi
  reset
  if "$2"; then ((pass++)); echo "  ok   $1"; else
    local rc=$?
    if (( rc == 77 )); then ((skip++)); echo "  skip $1 (ignored host file is local-only)"; return; fi
    ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"
  fi
}

off() { conf; run07 install; contains 'muse: opt-in' && [[ ! -e "$H/.local/bin/muse" && ! -e "$M" ]]; }
fresh_launcher() { run07 install; cmp -s "$TMP/launcher" "$H/.local/bin/muse" && [[ $(stat -c %a "$H/.local/bin/muse") == 755 ]]; }
transport() { run07 install; grep -q -- "--proto =https --tlsv1.2" "$STATE/calls" && contains 'muse launcher installed'; }
fresh_settings() { run07 install; json_is "$M" '{"schema_version":1,"contributor_mode_enabled":false}' && [[ $(stat -c %a "$M") == 600 ]]; }
rerun() { run07 install; snapshot > "$TMP/before"; : > "$STATE/calls"; run07 install; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && [[ ! -s "$STATE/calls" ]] && contains 'muse launcher present'; }
check_fresh() { snapshot > "$TMP/before"; run07; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && [[ ! -s "$STATE/calls" ]] && contains '[would]' && contains 'muse launcher missing'; }
check_drift() { ready; settings '{"contributor_mode_enabled":true,"theme":"dark"}'; t3 '{"other":1}'; snapshot > "$TMP/before"; run07; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && contains 'muse: contributor mode must be off' && contains 'muse: T3 provider missing'; }
invalid_download() { DOWNLOAD=$1; run07 install; [[ ! -e "$H/.local/bin/muse" ]] && clean_stage && contains 'MISS: muse: launcher download failed or invalid'; }
bad_html() { invalid_download html; }
bad_shebang() { invalid_download shebang; }
bad_url() { invalid_download url; }
bad_curl() { invalid_download failed; }
keep_launcher() { ready; printf '# keep this launcher\n' >> "$H/.local/bin/muse"; cp "$H/.local/bin/muse" "$TMP/original"; run07 install; cmp -s "$TMP/original" "$H/.local/bin/muse" && [[ ! -s "$STATE/calls" ]] && contains 'muse launcher present'; }
nonexec() { ready; chmod 644 "$H/.local/bin/muse"; run07 install; [[ -x "$H/.local/bin/muse" ]] && cmp -s "$TMP/launcher" "$H/.local/bin/muse"; }
never_execute() { run07 install; run07; ! grep -q 'muse executed' "$STATE/calls" && contains 'muse launcher present'; }
merge_settings() { ready; settings '{"schema_version":3,"contributor_mode_enabled":true,"theme":{"nested":[1,2]}}'; run07 install; json_is "$M" '{"schema_version":3,"contributor_mode_enabled":false,"theme":{"nested":[1,2]}}'; }
settings_mode() { ready; settings '{"contributor_mode_enabled":true}'; chmod 640 "$M"; run07 install; [[ $(stat -c %a "$M") == 640 ]] && json_is "$M" '{"contributor_mode_enabled":false}'; }
missing_key() { ready; settings '{"other":true}'; run07 install; json_is "$M" '{"other":true,"contributor_mode_enabled":false}'; }
false_identity() { ready; settings '{"contributor_mode_enabled":0}'; run07 install; json_is "$M" '{"contributor_mode_enabled":false}'; }
malformed() { ready; settings '{bad'; snapshot > "$TMP/before"; run07 install; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && contains 'MISS: muse: unreadable JSON in ~/.config/muse/settings.json' && contains 'left unchanged'; }
invalid_shape() { ready; settings '[]'; run07 install; json_is "$M" '[]' && contains 'MISS: muse: unreadable JSON in ~/.config/muse/settings.json'; }
provider_add() { ready; settings; t3 '{"theme":"dark","providerInstances":{"codex":{"driver":"codex","enabled":true}}}'; cp "$T" "$TMP/original-t3"; run07 install; json_is "$T" '{"theme":"dark","providerInstances":{"codex":{"driver":"codex","enabled":true},"muse":{"driver":"muse","enabled":true}}}' && contains 'muse: T3 provider added'; }
provider_backup() { ready; settings; t3 '{"theme":"dark"}'; chmod 640 "$T"; cp "$T" "$TMP/original-t3"; run07 install; local -a backups=("$T".bak-*-muse); [[ ${#backups[@]} == 1 && -f "${backups[0]}" && $(stat -c %a "$T") == 640 ]] && cmp -s "$TMP/original-t3" "${backups[0]}"; }
provider_once() { ready; settings; t3 '{}'; run07 install; snapshot > "$TMP/before"; run07 install; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && contains 'muse: T3 provider present'; }
provider_existing() { ready; settings; t3 '{"providerInstances":{"muse":{"driver":"muse","enabled":false,"label":"mine"}}}'; snapshot > "$TMP/before"; run07 install; snapshot > "$TMP/after"; cmp -s "$TMP/before" "$TMP/after" && contains 'muse: T3 provider present'; }
provider_bad() { ready; settings; t3 '{bad'; cp "$T" "$TMP/original-t3"; run07 install; cmp -s "$T" "$TMP/original-t3" && contains 'MISS: muse: unreadable JSON in ~/.t3/userdata/settings.json'; }
provider_absent() { ready; settings; run07 install; [[ ! -e "$H/.t3" ]] && contains 'muse: T3 not installed; provider skipped' && ! grep -q 'MISS:.*T3' "$TMP/out"; }
login_missing() { ready; settings; run07; contains '[WARN]  muse not signed in — run: muse login (Meta device flow; Brandon approves the link)'; }
login_empty() { ready; settings; touch "$H/.config/muse/auth.json"; run07; contains '[WARN]  muse not signed in — run: muse login (Meta device flow; Brandon approves the link)'; }
login_present() { ready; settings; printf 'inert auth fixture\n' > "$H/.config/muse/auth.json"; run07; contains '[ OK ]  muse signed in' && ! grep -q 'muse not signed in' "$TMP/out"; }
auth_unread() { ready; settings; printf 'inert auth fixture\n' > "$H/.config/muse/auth.json"; WATCH_AUTH=1; run07 install; grep -qx calibrated "$TMP/auth-watch" && ! grep -q 'auth opened or read' "$TMP/auth-watch" && contains 'muse signed in'; }
host_workstation() { grep -q '^component_muse=no' "$KIT_DIR/hosts/example.conf"; }
host_worker() { grep -q '^component_muse=yes' "$KIT_DIR/hosts/worker.example.conf" && [[ $(readlink "$KIT_DIR/profiles/worker/07-components.sh") == ../workstation/07-components.sh ]]; }
# Real host configs are intentionally gitignored and are not sent by dev-run.
host_beast() { [[ -e "$KIT_DIR/hosts/Beast-VM.conf" ]] || return 77; grep -q '^component_muse=yes' "$KIT_DIR/hosts/Beast-VM.conf"; }

check off off
check fresh-launcher fresh_launcher
check https-transport transport
check fresh-settings fresh_settings
check idempotent-rerun rerun
check check-fresh check_fresh
check check-drift check_drift
check html-refused bad_html
check shebang-refused bad_shebang
check url-refused bad_url
check curl-failure bad_curl
check existing-launcher keep_launcher
check nonexecutable-launcher nonexec
check launcher-never-run never_execute
check contributor-merge merge_settings
check settings-mode settings_mode
check contributor-missing missing_key
check contributor-false-type false_identity
check malformed-settings malformed
check settings-object invalid_shape
check t3-provider-add provider_add
check t3-backup provider_backup
check t3-idempotent provider_once
check t3-existing-preserved provider_existing
check t3-malformed provider_bad
check t3-absent-skipped provider_absent
check login-missing login_missing
check login-empty login_empty
check login-present login_present
check auth-size-only auth_unread
check workstation-flag host_workstation
check worker-flag host_worker
check beast-flag host_beast
printf '  %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
