#!/bin/bash
# reach=tailnet|ssh: how a worker is reached (2026-11-04, proxmox_setup_plan docs/router.md).
#
# Agent VMs (dev 105 first) sit on agentnet behind router 110; Beast reaches in by ssh through the router, and an
# agent VM must never reach Beast. A tailscale daemon on an agent VM is a path around the router: once joined to
# Brandon's tailnet it reaches Beast's tailnet address directly. So a host with reach=ssh gets no tailscale at
# all: no apt repo, no package, and the doctor flags one that is there. reach=tailnet (the default) is unchanged.
#
# Class: every Tailscale installer, component, verifier and operator instruction must respect reach.
#
# Contract:
#   R1. repo: group_worker=yes, reach=ssh → pkgs.tailscale.com NOT proposed; reach unset → proposed (calibration)
#   R2. repo: reach=ssh and a tailscale.list already present → warned, with the removal named
#   R3. packages: reach=ssh → tailscale not in the wanted set, and the reason is said; reach unset → in it
#   R4. doctor: reach=ssh, tailscale installed → WARN naming reach=ssh and the removal; never `tailscale up`
#   R5. doctor: reach=ssh, no tailscale → OK, says why there is none
#   R6. unknown reach → exit 3 before provisioning, including direct phases and bootstrap
set -uo pipefail
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
KIT_DIR="$TMP/kit"; mkdir -p "$KIT_DIR"
cp -a "$SOURCE_DIR"/{lib.sh,bootstrap.sh,verify.sh,profiles,components,manifests,hosts,CLAUDE.md} "$KIT_DIR/"
pass=0; fail=0
assert() { [[ -n "${CASE:-}" && "$1" != "$CASE"* ]] && return 0; if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
H="$TMP/home"; BIN="$TMP/bin"; mkdir -p "$BIN"
export GSETTINGS_BACKEND=memory DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/no-bus"
export CALLS="$TMP/calls" STATE="$TMP/state"; mkdir -p "$STATE"; : > "$CALLS"
conf() { printf 'profile=worker\nheadless=yes\ngroup_worker=yes\ngit_push=deny\ngit_auth=none\naws_profile=none\n%s\n' "$1" > "$TMP/host.conf"; }

# ---- R1/R2: the apt repo ----------------------------------------------------
SRC="$TMP/sources.list.d"; rm -rf "$SRC"; mkdir -p "$SRC"
repos() {
  env HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 APT_SOURCES_DIR="$SRC" \
    bash "$KIT_DIR/profiles/workstation/01-apt-repos.sh" "${MODE:-check}" > "$TMP/out" 2>&1
}
echo "repo"
conf ""; repos
assert "R1a. reach unset: tailscale repo proposed (calibration)" 'grep -q "pkgs.tailscale.com" "$TMP/out"'
conf "reach=ssh"; repos
assert "R1b. reach=ssh: tailscale repo NOT proposed" '! grep -q "pkgs.tailscale.com" "$TMP/out"'
printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu x main\n' > "$SRC/tailscale.list"
repos
assert "R2. reach=ssh, repo present: warned, removal named" \
  'grep -q "WARN.*tailscale.*reach=ssh" "$TMP/out" && grep -q "rm .*tailscale.list" "$TMP/out"'
rm -f "$SRC/tailscale.list"

# ---- R3: the wanted package set ----------------------------------------------
echo "packages"
wanted() { env HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash -c 'source "$1/lib.sh"; apt_wanted_pkgs' _ "$KIT_DIR" > "$TMP/out" 2>&1; }
conf ""; wanted
assert "R3a. reach unset: tailscale wanted (calibration)" 'grep -qx tailscale "$TMP/out"'
conf "reach=ssh"; wanted
assert "R3b. reach=ssh: tailscale not wanted, and the reason is said" \
  '! grep -qx tailscale "$TMP/out" && grep -q "reach=ssh" "$TMP/out"'

# ---- R4-R6: the doctor (03-headless) -----------------------------------------
echo "doctor (03-headless)"
for s in systemctl loginctl sudo lspci nvidia-smi apt-mark; do
  printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; is-enabled|is-active) exit 0;; esac\nexit 0\n' > "$BIN/$s"
done
printf '#!/bin/bash\necho "arn:aws:iam::1:user/pub"\nexit 0\n' > "$BIN/aws"
printf '#!/bin/bash\n[ "$*" = "status --json" ] && printf %s "{\\n  \\"BackendState\\": \\"NeedsLogin\\"\\n}\\n"\nexit 0\n' '%s' > "$TMP/tailscale.stub"
chmod +x "$BIN/"* "$TMP/tailscale.stub"
# Install state is independent of CLI presence, including a snap outside PATH.
cat > "$BIN/dpkg-query" <<'S'
#!/bin/bash
[[ "${*: -1}" == tailscale && -e "$STATE/deb" ]] && { echo 'install ok installed'; exit 0; }
exit 1
S
cat > "$BIN/snap" <<'S'
#!/bin/bash
echo "snap $*" >> "$CALLS"
[[ "$1" == list ]] && { [[ "$2" == tailscale && -e "$STATE/snap" ]]; exit $?; }
exit 0
S
cat > "$BIN/sudo" <<'S'
#!/bin/bash
echo "sudo $*" >> "$CALLS"
[[ "$*" == '-n true' ]] && exit 0
[[ "$1" == snap ]] && exec "$@"
exit 1
S
printf '#!/bin/bash\necho "curl $*" >> "$CALLS"\nexit 1\n' > "$BIN/curl"
printf '#!/bin/bash\necho "gsettings $*" >> "$CALLS"\nexit 0\n' > "$BIN/gsettings"
printf '#!/bin/bash\nexit 0\n' > "$BIN/flatpak"
chmod +x "$BIN/"*
NOTS="$TMP/nots"; mkdir -p "$NOTS"
python3 - "$NOTS" <<'PYTOOLS'
import os, pathlib, sys
out = pathlib.Path(sys.argv[1])
for folder in ('/usr/bin', '/bin'):
    for path in pathlib.Path(folder).iterdir():
        if path.name.startswith('tailscale') or not (path.is_file() or path.is_symlink()):
            continue
        target = out / path.name
        if not target.is_symlink():
            os.symlink(path, target)
PYTOOLS

doctor() {
  rm -rf "$H"; mkdir -p "$H/.ssh" "$H/.aws"; : > "$H/.aws/credentials"
  env PATH="$BIN:$NOTS" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/worker/03-headless.sh" check 2>&1 | grep -i 'tailscale\|tailnet\|reach' > "$TMP/out"
}
conf "reach=ssh"; touch "$STATE/deb"; cp "$TMP/tailscale.stub" "$BIN/tailscale"; doctor
assert "R4. reach=ssh, tailscale installed: WARN naming reach=ssh and the removal, never \`tailscale up\`" \
  'grep -q "WARN.*reach=ssh" "$TMP/out" && grep -q "apt-get remove" "$TMP/out" && ! grep -q "tailscale up" "$TMP/out"'
rm -f "$BIN/tailscale" "$STATE/deb"; doctor
assert "R5. reach=ssh, no tailscale: OK, says why" 'grep -q "OK.*reach=ssh" "$TMP/out" && ! grep -q "WARN" "$TMP/out"'
conf ""; cp "$TMP/tailscale.stub" "$BIN/tailscale"; doctor
assert "R6-control. default tailnet doctor still names joining" 'grep -q "tailscale up" "$TMP/out"'
rm -f "$BIN/tailscale"
conf "reach=sssh"; doctor; rc=$?
assert "R6-doctor. typo refuses with exit 3 and corrects the value" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach.*sssh" "$TMP/out" && ! grep -q "treated as tailnet" "$TMP/out"'

# ---- R9-1: workstation snap and both doctors -------------------------------
echo "snap reach policy"
snaps() { : > "$CALLS"; env PATH="$BIN:$NOTS" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/03-snap-flatpak.sh" "${MODE:-install}" > "$TMP/out" 2>&1; }
conf ""; snaps
assert "R9-1a. default tailnet installs the missing snap" 'grep -qx "snap install tailscale" "$CALLS"'
conf "reach=ssh"; snaps
assert "R9-1b. ssh installs no tailscale snap" '! grep -q "snap install tailscale" "$CALLS" && grep -q "reach=ssh" "$TMP/out"'
touch "$STATE/snap"; MODE=check snaps
assert "R9-1c. snap doctor names snap removal" 'grep -q "WARN.*snap.*reach=ssh" "$TMP/out" && grep -q "sudo snap remove tailscale" "$TMP/out" && ! grep -q "apt-get remove.*tailscale" "$TMP/out"'
doctor
assert "R9-1d. worker doctor sees a snap outside PATH, names snap removal" 'grep -q "WARN.*snap.*reach=ssh" "$TMP/out" && grep -q "sudo snap remove tailscale" "$TMP/out" && ! grep -q "apt-get remove.*tailscale" "$TMP/out"'
rm -f "$STATE/snap"; touch "$STATE/deb"; MODE=check snaps
assert "R9-1e. snap doctor names apt removal for a deb" 'grep -q "WARN.*apt.*reach=ssh" "$TMP/out" && grep -q "apt-get remove -y tailscale" "$TMP/out" && ! grep -q "sudo snap remove tailscale" "$TMP/out"'
doctor
assert "R9-1f. worker doctor sees a deb without its CLI" 'grep -q "WARN.*apt.*reach=ssh" "$TMP/out" && grep -q "apt-get remove -y tailscale" "$TMP/out"'
conf ""; MODE=check snaps
assert "R9-1g. default tailnet accepts an existing deb, no removal" 'grep -q "OK.*tailscale.*apt" "$TMP/out" && ! grep -q "remove.*tailscale" "$TMP/out"'
rm -f "$STATE/deb"; touch "$STATE/snap"; MODE=check snaps
assert "R9-1h. default tailnet accepts an existing snap, no removal" 'grep -q "OK.*snap tailscale" "$TMP/out" && ! grep -q "remove.*tailscale" "$TMP/out"'
rm -f "$STATE/snap"

# ---- R9-2: Serve conflicts and reconciliation ------------------------------
echo "t3code reach policy"
conf07() {
  conf "$1"
  printf '%s\n' tmp_on_disk=no component_resource_guards=no component_oom_zram=no \
    component_docker_rootless=skip group_dev_cloud=no component_clipboard=no component_herdr=no component_uutils_ls=no component_aws_cli=no \
    component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no \
    component_tts=no component_lid_ignore=no component_chatterbox=no component_t3code=yes \
    t3code_tailscale_serve=yes >> "$TMP/host.conf"
}
DROPIN="$H/.config/systemd/user/t3code.service.d/setup-kit.conf"
UNIT="$H/.config/systemd/user/t3code.service"
cat > "$BIN/t3" <<'S'
#!/bin/bash
echo "t3 $*" >> "$CALLS"
case "$*" in
  --version) echo 't3 v0.0.42' ;;
  'service install') mkdir -p "$(dirname "$HOME/.config/systemd/user/t3code.service")"
    printf '[Service]\nExecStart=t3 __service-launcher\n' > "$HOME/.config/systemd/user/t3code.service"
    cp "$HOME/.config/systemd/user/t3code.service.d/setup-kit.conf" "$STATE/start-dropin" ;;
esac
S
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$*" in
  get-default) echo multi-user.target ;;
  *restart*t3code.service*) cp "$HOME/.config/systemd/user/t3code.service.d/setup-kit.conf" "$STATE/start-dropin" ;;
esac
exit 0
S
cat > "$BIN/tailscale" <<'S'
#!/bin/bash
echo "tailscale $*" >> "$CALLS"
case "$*" in
  'debug prefs') echo '{"OperatorUser":"fixture"}' ;;
  'status --json') echo '{"BackendState":"Running","Self":{"DNSName":"box.tail.test."},"CertDomains":["box.tail.test"]}' ;;
esac
S
printf '#!/bin/bash\nexit 0\n' > "$BIN/claude"
chmod +x "$BIN/"*
components() { : > "$CALLS"; env PATH="$BIN:$NOTS" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-install}" > "$TMP/out" 2>&1; }
conf07 ""; components
assert "R9-2a. default tailnet writes Serve before starting T3" 'grep -qx "Environment=T3CODE_TAILSCALE_SERVE=true" "$DROPIN" && grep -q "T3CODE_TAILSCALE_SERVE=true" "$STATE/start-dropin" && grep -q "tailscale debug prefs" "$CALLS"'
rm -rf "$H/.config"; rm -f "$STATE/start-dropin"; conf07 "reach=ssh"; components
assert "R9-2b. ssh conflict: no Serve in first start, env or hints" 'grep -q "WARN.*reach=ssh.*t3code_tailscale_serve=yes" "$TMP/out" && [[ -f "$UNIT" && -f "$STATE/start-dropin" ]] && ! grep -q TAILSCALE_SERVE "$DROPIN" "$STATE/start-dropin" && ! grep -q "tailscale " "$CALLS" && ! grep -qE "pair --tailscale|sudo tailscale set" "$TMP/out"'
conf07 ""; components
printf 'operator-owned sentinel\n' > "${DROPIN%/*}/operator.conf"
cp "$DROPIN" "$TMP/serve-before"; conf07 "reach=ssh"; MODE=check components
assert "R9-2c. ssh doctor says conflict, preserves old setting and service" 'grep -q "WARN.*reach=ssh.*t3code_tailscale_serve=yes.*refusing Tailscale Serve" "$TMP/out" && cmp -s "$DROPIN" "$TMP/serve-before" && ! grep -qE "daemon-reload|restart|t3 service install|tailscale " "$CALLS"'
components
assert "R9-2d. ssh install removes owned Serve setting before restart" '! grep -q TAILSCALE_SERVE "$DROPIN" "$STATE/start-dropin" && grep -q T3CODE_HOST "$DROPIN" && grep -q "daemon-reload" "$CALLS" && grep -q "restart t3code.service" "$CALLS" && grep -qx "operator-owned sentinel" "${DROPIN%/*}/operator.conf"'
rm -f "$BIN/tailscale"

# ---- R6: explicit invalid values fail before every provisioning seam --------
echo "invalid reach refusal"
for bad in reach=sssh reach= 'reach="unknown" # inline comment'; do
  conf07 "$bad"; : > "$CALLS"; MODE=install repos; rc=$?
  assert "R6-repo. $bad refuses before repo actions" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach" "$TMP/out" && ! grep -q pkgs.tailscale.com "$TMP/out" && [[ ! -s "$CALLS" ]] && [[ ! -e "$SRC/tailscale.list" ]]'
  : > "$CALLS"; wanted; rc=$?
  assert "R6-package. $bad refuses without a wanted package set" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach" "$TMP/out" && ! grep -qx tailscale "$TMP/out" && [[ ! -s "$CALLS" ]]'
  snaps; rc=$?
  assert "R6-snap. $bad refuses without snap actions" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach" "$TMP/out" && [[ ! -s "$CALLS" ]]'
  rm -rf "$H/.config"; components; rc=$?
  assert "R6-serve. $bad refuses before writing or starting Serve" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach" "$TMP/out" && [[ ! -s "$CALLS" && ! -e "$DROPIN" && ! -e "$UNIT" ]]'
done
mkdir -p "$TMP/phases"
printf '#!/bin/bash\necho PREAMBLE >> "$CALLS"\n' > "$TMP/phases/preamble-github-auth.sh"
printf '#!/bin/bash\necho PHASE >> "$CALLS"\n' > "$TMP/phases/00-provision.sh"
bootstrap() { : > "$CALLS"; env PATH="$BIN:$NOTS" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_PHASE_DIR="$TMP/phases" KIT_SKIP_VERIFY=1 \
  bash "$KIT_DIR/bootstrap.sh" "$1" "$2" > "$TMP/out" 2>&1; }
for profile in workstation worker; do
  conf ""; bootstrap "$profile" check
  assert "R6-loop-control. $profile default tailnet reaches phases" 'grep -qx PREAMBLE "$CALLS" && grep -qx PHASE "$CALLS"'
  conf 'reach="tailnet" # explicit supported value'; bootstrap "$profile" check
  assert "R6-explicit-control. $profile quoted tailnet reaches phases" 'grep -qx PHASE "$CALLS"'
  conf reach=sssh; bootstrap "$profile" install; rc=$?
  assert "R6-loop. $profile unknown value stops before sudo, preamble or phases" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach.*sssh" "$TMP/out" && [[ ! -s "$CALLS" ]]'
done

# First-run interactive editing happens after bootstrap first loads lib.sh.
cat > "$TMP/editor" <<'S'
#!/bin/bash
echo EDIT >> "$CALLS"
printf 'reach=%s\n' "$REACH_EDIT" >> "$1"
S
chmod +x "$TMP/editor"
edit_bootstrap() {
  rm -f "$TMP/host.conf"; : > "$CALLS"
  env PATH="$BIN:$NOTS" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_PHASE_DIR="$TMP/phases" KIT_SKIP_VERIFY=1 \
    EDITOR="$TMP/editor" REACH_EDIT="$1" python3 - "$KIT_DIR" "$TMP/out" <<'PYEDIT'
import os, pty, signal, subprocess, sys
master, slave = pty.openpty()
try:
    with open(sys.argv[2], 'w') as out:
        proc = subprocess.Popen(['bash', sys.argv[1] + '/bootstrap.sh', 'worker', 'install'],
                                stdin=slave, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        os.write(master, b'\n')
        try:
            rc = proc.wait(timeout=20)
        finally:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
finally:
    os.close(master)
    os.close(slave)
sys.exit(rc)
PYEDIT
}
edit_bootstrap tailnet
assert "R6-editor-control. first-run editor can keep tailnet and provision" 'grep -qx EDIT "$CALLS" && grep -qx PHASE "$CALLS"'
edit_bootstrap sssh; rc=$?
assert "R6-editor. typo introduced by editor stops before sudo or preamble" '[[ "$rc" == 3 ]] && grep -q "FAIL.*reach.*sssh" "$TMP/out" && [[ "$(cat "$CALLS")" == EDIT ]]'

# ---- R9-4: independent verification ---------------------------------------
echo "independent verifier reach policy"
cat > "$BIN/apt-cache" <<'S'
#!/bin/bash
[[ "$*" == 'show tailscale' ]]
S
cat > "$BIN/snap" <<'S'
#!/bin/bash
echo "snap $*" >> "$CALLS"
[[ "$1" == list ]] || exit 0
[[ "$2" != tailscale || -e "$STATE/snap" ]]
S
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
if [[ "$*" == *is-active* ]]; then
  [[ "${*: -1}" == tailscaled.service && -e "$STATE/service" ]] && exit 0
  [[ "${*: -1}" == snap.tailscale.tailscaled.service && -e "$STATE/snap-service" ]] && exit 0
  exit 1
fi
exit 0
S
cat > "$BIN/pgrep" <<'S'
#!/bin/bash
[[ "$*" == '-x tailscaled' && -e "$STATE/process" ]]
S
for cmd in journalctl coredumpctl dpkg gh; do printf '#!/bin/bash\nexit 0\n' > "$BIN/$cmd"; done
mkdir -p "$H/.pyenv/bin" "$H/.pyenv/versions/3.12/bin"
printf '#!/bin/bash\ncase "$1" in global) echo system ;; versions) echo 3.12 ;; esac\nexit 0\n' > "$H/.pyenv/bin/pyenv"
printf '#!/bin/bash\nexit 0\n' > "$H/.pyenv/versions/3.12/bin/python"
chmod +x "$BIN/"* "$H/.pyenv/bin/pyenv" "$H/.pyenv/versions/3.12/bin/python"
confv() { conf07 "$1"; printf '%s\n' configs=no dock=no lang_node=no lang_flutter=no component_t3code=no "headless=${2:-yes}" >> "$TMP/host.conf"; [[ "${2:-yes}" != no ]] || printf 'profile=workstation\ngroup_worker=no\n' >> "$TMP/host.conf"; }
verify() { : > "$CALLS"; env PATH="$BIN:$NOTS" HOME="$H" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 \
  bash "$KIT_DIR/verify.sh" > "$TMP/out" 2>&1; }
confv ""; verify
assert "R9-4a. default worker still requires apt tailscale" 'grep -q "FAIL.*apt: tailscale" "$TMP/out"'
confv 'reach="ssh" # router-only access'; verify; rc=$?
assert "R9-4b. ssh worker with no tailscale passes the reach policy" '[[ "$rc" == 0 ]] && grep -q "PASS.*reach=ssh.*no tailscale" "$TMP/out" && ! grep -q "FAIL.*tailscale" "$TMP/out"'
touch "$STATE/deb"; verify
assert "R9-4c. ssh detects forbidden apt package without CLI" 'grep -q "FAIL.*reach=ssh.*tailscale.*apt" "$TMP/out" && grep -q "apt-get remove -y tailscale" "$TMP/out"'
confv ""; verify
assert "R9-4d. default worker accepts its installed apt package" '! grep -q "FAIL.*tailscale" "$TMP/out" && grep -q "PASS.*manifest packages installed" "$TMP/out"'
rm -f "$STATE/deb"; confv "" no; verify
assert "R9-4e. default workstation still requires the snap" 'grep -q "FAIL.*snap: tailscale" "$TMP/out"'
confv reach=ssh no; verify; rc=$?
assert "R9-4f. ssh workstation excludes positive snap requirement" '[[ "$rc" == 0 ]] && grep -q "PASS.*reach=ssh.*no tailscale" "$TMP/out" && ! grep -q "FAIL.*tailscale" "$TMP/out"'
touch "$STATE/snap"; verify
assert "R9-4g. ssh diagnoses installed snap without CLI" 'grep -q "FAIL.*reach=ssh.*tailscale.*snap" "$TMP/out" && grep -q "sudo snap remove tailscale" "$TMP/out"'
confv "" no; verify
assert "R9-4h. default workstation accepts its installed snap" 'grep -q "PASS.*snap: tailscale" "$TMP/out" && ! grep -q "FAIL.*tailscale" "$TMP/out"'
confv reach=ssh; verify
assert "R9-4i. headless ssh still detects a leftover snap" 'grep -q "FAIL.*reach=ssh.*tailscale.*snap" "$TMP/out"'
rm -f "$STATE/snap"
for marker in service snap-service process; do
  touch "$STATE/$marker"; verify
  assert "R9-4j. ssh detects running $marker without a package or CLI" 'grep -q "FAIL.*reach=ssh.*tailscale.*running" "$TMP/out"'
  confv ""; verify
  assert "R9-4k. default tailnet permits running $marker" '! grep -q "FAIL.*reach=ssh" "$TMP/out" && ! grep -q "FAIL.*tailscale.*running" "$TMP/out"'
  rm -f "$STATE/$marker"; confv reach=ssh
done
cp "$TMP/tailscale.stub" "$BIN/tailscale"; verify
assert "R9-4l. ssh detects an unmanaged binary" 'grep -q "FAIL.*reach=ssh.*tailscale.*binary" "$TMP/out"'
confv ""; verify
assert "R9-4m. default tailnet permits an unmanaged binary" '! grep -q "FAIL.*tailscale.*binary" "$TMP/out"'
rm -f "$BIN/tailscale"; cp "$TMP/tailscale.stub" "$BIN/tailscaled"; confv reach=ssh; verify
assert "R9-4n. ssh detects a daemon binary without its CLI" 'grep -q "FAIL.*reach=ssh.*tailscale.*binary" "$TMP/out"'
confv ""; verify
assert "R9-4o. default tailnet permits a daemon binary" '! grep -q "FAIL.*tailscale.*binary" "$TMP/out"'
rm -f "$BIN/tailscaled"
confv reach=sssh; verify; rc=$?
assert "R9-4p. verifier refuses unknown reach independently" '[[ "$rc" != 0 ]] && grep -q "FAIL.*reach.*sssh" "$TMP/out"'
# A deliberately broken installer library must have no effect on the verifier.
cp "$KIT_DIR/lib.sh" "$TMP/lib-before-poison"
printf '\nexit 77\n' >> "$KIT_DIR/lib.sh"
confv reach=ssh; verify
assert "R9-4q. verifier does not source the installer library" 'grep -q "PASS.*reach=ssh.*no tailscale" "$TMP/out"'

cp "$TMP/lib-before-poison" "$KIT_DIR/lib.sh"

# ---- R9-8: operator instructions and worker template -----------------------
echo "worker reach documentation"
cp "$KIT_DIR/hosts/worker.example.conf" "$TMP/host.conf"; wanted
assert "R9-8a. worker template declares tailnet default and retains its package" 'grep -q "^reach=tailnet" "$KIT_DIR/hosts/worker.example.conf" && grep -qx tailscale "$TMP/out"'
printf 'reach=ssh\n' >> "$TMP/host.conf"; wanted
assert "R9-8b. worker template can exclude tailscale for agentnet" '! grep -qx tailscale "$TMP/out" && grep -q reach=ssh "$TMP/out"'
sed -n '/^## Tailnet/,/^## Wiring/p' "$KIT_DIR/profiles/worker/99-manual-checklist.md" > "$TMP/out"
assert "R9-8c. checklist limits join and Serve to tailnet, excludes agentnet" 'grep -q "reach=tailnet only" "$TMP/out" && grep -q "Agentnet workers.*reach=ssh.*stay off the tailnet" "$TMP/out" && grep -q "sudo tailscale up" "$TMP/out" && grep -q "Tailscale Serve" "$TMP/out"'
sed -n '/worker check|install/,/Template/p' "$KIT_DIR/CLAUDE.md" > "$TMP/out"
assert "R9-8d. worker description qualifies package, join and Serve" 'grep -q "reach=tailnet only" "$TMP/out" && grep -q "agentnet workers stay off the tailnet" "$TMP/out" && grep -q group_worker "$TMP/out" && grep -q "tailscale up" "$TMP/out" && grep -q "Tailscale Serve" "$TMP/out"'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
