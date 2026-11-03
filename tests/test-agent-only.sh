#!/bin/bash
# Every path that activates workstation identity on an agent host must stop
# before the side effect. Exercise the real phase entry points in an archive,
# with a fake HOME and recorded/stubbed external commands. CASE selects one
# group for revert-and-watch; no network, sudo, or real credentials are used.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; K="$H/repos/setup-kit"; BIN="$TMP/bin"; CALLS="$TMP/calls"
mkdir -p "$K" "$BIN"
cp -a "$KIT_DIR"/{lib.sh,bootstrap.sh,get.sh,verify.sh,profiles,components,manifests,hosts} "$K/"
export CALLS FIXTURE="$TMP/configs-source" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
mkdir -p "$FIXTURE/.git" "$FIXTURE/bin" "$FIXTURE/.claude" "$FIXTURE/dconf" \
  "$FIXTURE/.local/share/applications" "$FIXTURE/.local/share/icons" "$FIXTURE/.config/autostart"
for f in .bashrc .bash_aliases .gitconfig .claude/CLAUDE.md .claude/settings.json \
  .claude/statusline-command.sh bin/personal-tool dconf/test.ini \
  .local/share/applications/test.desktop .local/share/icons/test.svg .config/autostart/test.desktop; do
  echo 'fixture' > "$FIXTURE/$f"
done
chmod +x "$FIXTURE/bin/personal-tool"
for f in .local/share/applications/test.desktop .config/autostart/test.desktop; do
  printf '[Desktop Entry]\nExec=true\nIcon=agent-fixture-icon\n' > "$FIXTURE/$f"
done
mv "$FIXTURE/.local/share/icons/test.svg" "$FIXTURE/.local/share/icons/agent-fixture-icon.svg"
cat > "$FIXTURE/setup.sh" <<'S'
#!/bin/bash
echo "configs $*" >> "$CALLS"
exit "${DOCTOR_RC:-0}"
S
chmod +x "$FIXTURE/setup.sh"
cat > "$BIN/git" <<'S'
#!/bin/bash
echo "git $*" >> "$CALLS"
if [[ "$1" == clone ]]; then
  [[ "${CLONE_FAIL:-0}" == 1 ]] && exit 128
  if [[ "$2" == git-hub:* && ! -f "$HOME/.ssh/config" ]]; then exit 128; fi
  if [[ -d "$2" || -f "$2" ]]; then exec /usr/bin/git "$@"; fi
  cp -a "$FIXTURE" "${@: -1}"; exit 0
fi
case "$*" in *'remote get-url origin') echo https://github.com/example/setup-kit.git ;; esac
exit 0
S
for c in gh ssh ssh-keygen ssh-keyscan aws gpg pass scdaemon gsettings dconf gnome-extensions curl bun sudo sysctl lspci; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$c" > "$BIN/$c"
done
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$*" in get-default) echo multi-user.target ;; *graphical.target*) exit 1 ;; esac
S
printf '#!/bin/bash\necho yes\n' > "$BIN/loginctl"
printf '#!/bin/bash\necho no\n' > "$BIN/systemd-detect-virt"
printf '#!/bin/bash\necho "{\"BackendState\":\"NeedsLogin\"}"\n' > "$BIN/tailscale"
chmod +x "$BIN"/*
export HOME="$H" GIT_HOME="$H/repos" PATH="$BIN:/usr/bin:/bin" USER=agents
export HOST_CONF="$TMP/host.conf" KIT_HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_VERBOSE=1
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/bus"
pass=0; fail=0; rc=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; tail -12 "$TMP/out" | sed 's/^/       | /'; fi; }
conf() { printf '%s\n' profile=worker headless=yes configs_role=agent git_auth=none aws_profile=none cond_nvidia=no "$@" > "$HOST_CONF"; }
reset_home() { rm -rf "$H/repos/.configs" "$H/git/.configs" "$H/.claude" "$H/bin" "$H/.local" "$H/.config" "$H/.ssh" "$H/.gitconfig" "$H/.bashrc" "$H/.bash_aliases"; mkdir -p "$H/.ssh"; }
present() { cp -a "$FIXTURE" "$H/repos/.configs"; }
run() { : > "$CALLS"; bash "$K/$1" "${2:-install}" > "$TMP/out" 2>&1; rc=$?; }
tty_run() {
  : > "$CALLS"
  python3 - "$K/$1" > "$TMP/out" 2>&1 <<'PY'
import os,pty,subprocess,sys
m,s=pty.openpty(); os.write(m,b'n\n')
try: p=subprocess.run(['bash',sys.argv[1],'install'],stdin=s,timeout=8); sys.exit(p.returncode)
finally: os.close(m); os.close(s)
PY
  rc=$?
}
if [[ "${CASE:-all}" == all || "${CASE:-}" == role ]]; then
  reset_home; present; conf configs_run_setup=no
  run profiles/worker/06-configs.sh
  assert 'R1 install delegates the role even when configs_run_setup=no' '[[ $rc == 0 ]] && grep -qx "configs install --role agent" "$CALLS"'
  assert 'R2 fixed dotfiles are not linked by setup-kit' '[[ ! -L "$H/.gitconfig" && ! -L "$H/.bash_aliases" && ! -L "$H/.bashrc" && ! -e "$H/.claude" ]]'
  assert 'R3 blanket bin and desktop trees are not linked' '[[ ! -e "$H/bin/personal-tool" && ! -e "$H/.local/share/applications/test.desktop" && ! -e "$H/.config/autostart/test.desktop" ]]'
  run profiles/worker/06-configs.sh check
  assert 'R4 check delegates the role doctor' 'grep -qx "configs check --role agent" "$CALLS"'
  DOCTOR_RC=7 run profiles/worker/06-configs.sh check
  assert 'R5 a failed role doctor is a failed phase' '[[ $rc != 0 ]]'
  rm "$H/repos/.configs/setup.sh"; run profiles/worker/06-configs.sh check
  assert 'R6 a missing role installer is a failed phase' '[[ $rc != 0 ]] && grep -q "setup.sh" "$TMP/out"'
  reset_home; present; conf configs_role=typo
  run profiles/worker/06-configs.sh
  assert 'R7 invalid role fails before calling setup or linking files' '[[ $rc != 0 ]] && ! grep -q "^configs " "$CALLS" && [[ ! -e "$H/.gitconfig" ]]'
  # A populated legacy source tree makes an accidentally ungated verifier
  # observable. An absent source would make its find/glob loops measure zero.
  rm -rf "$H/git/.configs"; mkdir -p "$H/git"; cp -a "$FIXTURE" "$H/git/.configs"
  conf; run verify.sh
  assert 'R8 verifier delegates the agent doctor' 'grep -qx "configs check --role agent" "$CALLS" && ! grep -qE "FAIL.*(dotfile:|bin:|launcher|autostart)" "$TMP/out"'
  DOCTOR_RC=7 run verify.sh
  assert 'R9 verifier reports a failed agent doctor' 'grep -q "FAIL.*agent" "$TMP/out"'
  conf configs_role=typo; run verify.sh
  assert 'R10 verifier rejects invalid role' 'grep -q "FAIL.*configs_role" "$TMP/out"'
  conf headless=no; run profiles/worker/06-configs.sh
  assert 'R11 agent delegates without desktop links even if headless=no' '[[ $rc == 0 ]] && grep -qx "configs install --role agent" "$CALLS" && [[ ! -e "$H/.local/share/applications/test.desktop" ]]'
  rm -rf "$H/.config/autostart" "$H/.local/share/applications" "$H/.local/share/icons" "$H/bin/personal-tool"
  run verify.sh
  assert 'R12 verifier also omits launcher and autostart checks for the agent role' '! grep -qE "FAIL.*(dotfile:|bin:|launcher|autostart)" "$TMP/out"'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == auth ]]; then
  reset_home; conf configs_repo=git-hub:.configs.git
  CLONE_FAIL=1 tty_run profiles/worker/preamble-github-auth.sh
  assert 'N1 preamble defers an unavailable hub with a warning and success' '[[ $rc == 0 ]] && grep -q "WARN.*phase 06" "$TMP/out" && ! grep -q "\[FAIL\]" "$TMP/out"'
  assert 'N2 none does not seed GitHub hosts, credentials or keys' '! grep -qE "^(gh |ssh|git config|sudo )" "$CALLS" && [[ ! -e "$H/.ssh/known_hosts" ]]'
  conf configs_repo=git-hub:.configs.git git_hub=hub.test git_hub_repos="example/setup-kit example/.configs" clone_repos=example/job
  run profiles/worker/03-headless.sh
  assert 'N3 phase 03 skips GitHub checks and job clones by name' 'grep -q "OK.*git_auth=none" "$TMP/out" && ! grep -qE "^(gh |git clone|git config)" "$CALLS" && ! grep -q "names no mode" "$TMP/out"'
  assert 'N4 phase 03 still creates the private hub alias' 'grep -q "Host git-hub" "$H/.ssh/config"'
  run profiles/worker/06-configs.sh
  assert 'N5 phase 06 retries the configured hub source after the alias exists' '[[ $rc == 0 ]] && grep -qx "git clone git-hub:.configs.git $H/repos/.configs" "$CALLS" && grep -qx "configs install --role agent" "$CALLS"'
  reset_home; conf configs_repo=missing-local-source
  CLONE_FAIL=1 tty_run profiles/worker/06-configs.sh
  assert 'N6 clone failure never offers gh login on a tty' '[[ $rc != 0 ]] && ! grep -q "^gh " "$CALLS" && ! grep -q "gh auth login" "$TMP/out"'
  assert 'N7 clone failure names source availability instead of GitHub auth' 'grep -q "clone failed" "$TMP/out" && ! grep -q "needs GitHub auth" "$TMP/out"'
  reset_home; conf configs=no; run profiles/worker/preamble-github-auth.sh
  assert 'N8 configs=no plus none attempts no clone' '! grep -q "^git clone" "$CALLS"'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == aws ]]; then
  reset_home
  for value in none empty; do
    conf; [[ "$value" == empty ]] && echo 'aws_profile=' >> "$HOST_CONF"
    run profiles/worker/03-headless.sh
    assert "A1 $value skips the AWS credential section explicitly" 'grep -q "OK.*no machine AWS credential is wanted on this box" "$TMP/out" && ! grep -qE "^aws |seal-aws-profile|aws configure" "$CALLS" "$TMP/out"'
  done
  conf aws_profile=cron-deploy; run profiles/worker/03-headless.sh
  assert 'A2 cron-deploy still makes the STS call' 'grep -q "^aws --profile cron-deploy sts get-caller-identity" "$CALLS"'
  sed -i '/^aws_profile=/d' "$HOST_CONF"; run profiles/worker/03-headless.sh
  assert 'A3 unset aws_profile still defaults to cron-deploy' 'grep -q "^aws --profile cron-deploy sts get-caller-identity" "$CALLS"'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == archive ]]; then
  reset_home; present; conf git_auth=deploy-keys headless=no
  run profiles/worker/06-configs.sh check
  assert 'X1 archive skips remote inspection explicitly, without ancestor git discovery' 'grep -q "OK.*archive.*remote" "$TMP/out" && ! grep -q "git -C $K " "$CALLS"'
  conf git_hub=hub.test git_hub_repos=example/setup-kit
  run profiles/worker/03-headless.sh
  assert 'X2 archive is a supported hub entry, without a remote probe' 'grep -q "OK.*setup-kit.*archive" "$TMP/out" && ! grep -q "git -C $K " "$CALLS"'
  : > "$CALLS"; SETUP_KIT_DIR="$K" bash "$K/get.sh" > "$TMP/out" 2>&1; rc=$?
  assert 'X3 get.sh can reuse an extracted archive without cloning over it' '[[ $rc == 0 ]] && grep -q "archive" "$TMP/out" && ! grep -q "^git " "$CALLS"'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == clone ]]; then
  # Real local git proves both repository directories and bundle files work.
  REAL_SRC="$TMP/real-source"; mkdir -p "$REAL_SRC"
  /usr/bin/git init -q -b main "$REAL_SRC"
  cp "$FIXTURE/setup.sh" "$REAL_SRC/setup.sh"
  /usr/bin/git -C "$REAL_SRC" add setup.sh
  /usr/bin/git -C "$REAL_SRC" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
  /usr/bin/git -C "$REAL_SRC" bundle create "$TMP/configs.bundle" --all
  for source in "$REAL_SRC" "$TMP/configs.bundle"; do
    reset_home; conf "configs_repo=$source"; run profiles/worker/preamble-github-auth.sh
    assert "C1 preamble clones $(basename "$source") with real git" '[[ $rc == 0 && -d "$H/repos/.configs/.git" ]]'
    reset_home; conf "configs_repo=$source"; run profiles/worker/06-configs.sh
    assert "C2 phase 06 clones $(basename "$source") and delegates" '[[ $rc == 0 && -d "$H/repos/.configs/.git" ]] && grep -qx "configs install --role agent" "$CALLS"'
  done
  reset_home; conf "configs_repo=$REAL_SRC"; GIT_HOME='' run profiles/worker/06-configs.sh
  assert 'C3 unset GIT_HOME derives the repo parent of the archive' '[[ $rc == 0 && -d "$H/repos/.configs/.git" ]]'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == list ]]; then
  # Every catalog value filling its column needs an explicit separator; the
  # seven-character [agent] value must not run into the following key.
  for profile in worker workstation; do
    conf "profile=$profile"; run bootstrap.sh list
    assert "L1 $profile lists the current configs_role and description" 'grep -qE "\[agent\][[:space:]]+configs_role[[:space:]]+.*full.*agent" "$TMP/out"'
  done
  conf; sed -i '/^configs_role=/d' "$HOST_CONF"; run bootstrap.sh list
  assert 'L2 unset role lists full as its default' 'grep -qE "\[full\][[:space:]]+configs_role" "$TMP/out"'
fi
if [[ "${CASE:-all}" == all || "${CASE:-}" == audit ]]; then
  reset_home; present; conf
  run profiles/workstation/06-gpg-pass.sh
  assert 'I1 agent skips the personal GPG/pass chain before any calls' 'grep -q "OK.*configs_role=agent" "$TMP/out" && ! grep -qE "^(gpg |pass |scdaemon |systemctl )" "$CALLS" && [[ ! -e "$H/.gnupg" ]]'
  # Complete skill sources: no stale pull, no personal-browser workflow.
  CONDUCT="$H/repos/.configs/claude-conduct"; GS="$H/repos/gstack"
  mkdir -p "$CONDUCT/agents" "$CONDUCT/skills/conduct/templates" "$GS/.git" "$GS/browse/dist" "$GS/setup-browser-cookies"
  for s in conduct vault filmstrip; do mkdir -p "$CONDUCT/skills/$s"; touch "$CONDUCT/skills/$s/SKILL.md"; done
  touch "$CONDUCT/skills/conduct/templates/vault-digest" "$CONDUCT/agents/reviewer.md" "$GS/SKILL.md" "$GS/browse/SKILL.md" "$GS/setup-browser-cookies/SKILL.md"
  printf '#!/bin/sh\nexit 0\n' > "$GS/browse/dist/browse"; chmod +x "$GS/browse/dist/browse"
  # A complete legacy layout makes cookie-default calibration observable on
  # main too; a missing checkout must not hide an unwanted skill link.
  mkdir -p "$H/git"; cp -a "$H/repos/.configs" "$H/git/.configs"; cp -a "$GS" "$H/git/gstack"
  conf component_claude_code=no gstack_skills=browse component_claude_brevity=no
  run profiles/worker/08-claude-skills.sh
  assert 'I2 agent gets conduct skill links from the sibling configs checkout' '[[ "$(readlink -f "$H/.claude/skills/conduct")" == "$CONDUCT/skills/conduct" && "$(readlink -f "$H/.claude/skills/filmstrip")" == "$CONDUCT/skills/filmstrip" ]]'
  assert 'I3 browse is linked and personal browser cookie workflow is absent' '[[ -L "$H/.claude/skills/browse/SKILL.md" && ! -e "$H/.claude/skills/setup-browser-cookies" ]]'
  assert 'I4 shared agents and vault-digest remain available' '[[ "$(readlink -f "$H/.claude/agents/reviewer.md")" == "$CONDUCT/agents/reviewer.md" && "$(readlink -f "$H/bin/vault-digest")" == "$CONDUCT/skills/conduct/templates/vault-digest" ]]'
  assert 'I5 no GitHub auth, identity git config, or desktop commands in phase 08' '! grep -qE "^(gh |ssh |git config|gpg |gsettings |dconf |systemctl )" "$CALLS" && [[ ! -e "$H/.claude/settings.json" ]]'
  conf component_claude_code=no; run profiles/worker/08-claude-skills.sh
  assert 'I7 agent default also excludes the personal browser cookie workflow' '[[ ! -e "$H/.claude/skills/setup-browser-cookies" ]]'
  conf component_claude_code=no 'gstack_skills="browse setup-browser-cookies"'; run profiles/worker/08-claude-skills.sh
  assert 'I8 agent rejects the cookie workflow even if named explicitly' '[[ ! -e "$H/.claude/skills/setup-browser-cookies" ]]'
  # Missing conduct source must reuse configs_repo, never the private GitHub URL.
  rm -rf "$H/repos/.configs" "$H/git/.configs"; conf claude_skills=conduct configs_repo=git-hub:.configs.git component_claude_code=no
  echo 'Host git-hub' > "$H/.ssh/config"; run profiles/worker/08-claude-skills.sh
  assert 'I6 phase 08 honors the configured configs source' 'grep -qx "git clone git-hub:.configs.git $H/repos/.configs" "$CALLS" && ! grep -q "github.com:hotpocket/.configs" "$CALLS"'
fi
echo "agent-only: $pass passed, $fail failed"
(( fail == 0 ))
