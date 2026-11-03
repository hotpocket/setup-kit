#!/bin/bash
# Golden comparison: fixtures are the normalized calls and links recorded by
# these same stubs against main before the agent role was added. To reproduce:
# GOLDEN_KIT_DIR=<main archive> RECORD_GOLDEN=<output dir> bash <this test>.
# Main is read as data; tests never need GitHub, sudo, or a real user profile.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; K="$H/git/setup-kit"; BIN="$TMP/bin"; CALLS="$TMP/calls"
mkdir -p "$K" "$BIN" "$K/.git" "$H/.ssh"
cp -a "${GOLDEN_KIT_DIR:-$KIT_DIR}"/{lib.sh,profiles,components,manifests} "$K/"
export CALLS HOME="$H" USER=fixture GIT_HOME="$H/git"
export HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="$BIN:/usr/bin:/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
cat > "$BIN/git" <<'S'
#!/bin/bash
echo "git $*" >> "$CALLS"
case "$*" in
  clone*) mkdir -p "${@: -1}/.git" ;;
  *'remote get-url origin') echo https://github.com/example/setup-kit.git ;;
esac
exit 0
S
for c in ssh-keygen gh aws lspci systemd-detect-virt update-desktop-database; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$c" > "$BIN/$c"
done
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$*" in get-default) echo multi-user.target ;; *graphical.target*) exit 1 ;; esac
S
printf '#!/bin/bash\necho "loginctl $*" >> "$CALLS"\necho yes\n' > "$BIN/loginctl"
printf '#!/bin/bash\necho "ssh $*" >> "$CALLS"\necho authenticated\n' > "$BIN/ssh"
printf '#!/bin/bash\necho "tailscale $*" >> "$CALLS"\necho "{\"BackendState\":\"NeedsLogin\"}"\n' > "$BIN/tailscale"
printf '#!/bin/bash\necho fixture-host\n' > "$BIN/hostname"
chmod +x "$BIN"/*
pass=0; fail=0
capture() {
  local name="$1" phase="$2" mode="$3" df
  : > "$CALLS"
  bash "$K/$phase" "$mode" > "$TMP/out" 2>&1
  { cat "$CALLS"; find "$H" -path "$K" -prune -o -type l -printf 'LINK %p -> %l\n' | sort; } \
    | sed "s|$TMP|<TMP>|g" > "$TMP/$name"
  if [[ -n "${RECORD_GOLDEN:-}" ]]; then
    mkdir -p "$RECORD_GOLDEN"; cp "$TMP/$name" "$RECORD_GOLDEN/$name"; return
  fi
  if diff -u "$KIT_DIR/tests/fixtures/agent-default-calls/$name" "$TMP/$name"; then
    ((pass++)); echo "  ok   $name matches main"
  else ((fail++)); echo "  FAIL $name changed from main"; fi
}
for role in unset full; do
 for headless in yes no; do
  rm -rf "$H/git/.configs" "$H/bin" "$H/.claude" "$H/.gitconfig" "$H/.bashrc" "$H/.bash_aliases" "$H/.local" "$H/.config"
  D="$H/git/.configs"; mkdir -p "$D/.git" "$D/bin" "$D/.claude" "$D/.local/share/applications" "$D/.local/share/icons" "$D/.config/autostart" "$D/dconf"
  for f in .bashrc .bash_aliases .gitconfig .claude/CLAUDE.md .claude/settings.json .claude/statusline-command.sh bin/example; do
    echo fixture > "$D/$f"
  done
  chmod +x "$D/bin/example"
  printf '[Desktop Entry]\nExec=true\nIcon=example\n' > "$D/.local/share/applications/example.desktop"
  cp "$D/.local/share/applications/example.desktop" "$D/.config/autostart/example.desktop"
  touch "$D/.local/share/icons/example.svg" "$D/dconf/example.ini"
  printf '#!/bin/bash\necho "configs $*" >> "$CALLS"\n' > "$D/setup.sh"; chmod +x "$D/setup.sh"
  printf '%s\n' "headless=$headless" configs_run_setup=yes > "$HOST_CONF"
  [[ "$role" == full ]] && echo configs_role=full >> "$HOST_CONF"
  capture "06-$role-headless-$headless-install" profiles/workstation/06-configs.sh install
  capture "06-$role-headless-$headless-check" profiles/workstation/06-configs.sh check
 done
done
printf '%s\n' cond_nvidia=no git_auth=deploy-keys deploy_repos=configs=example/.configs aws_profile=cron-deploy > "$HOST_CONF"
echo 'ssh-ed25519 fixture' > "$H/.ssh/authorized_keys"
capture 03-deploy-keys profiles/worker/03-headless.sh check
printf '%s\n' cond_nvidia=no git_auth=token aws_profile=cron-deploy > "$HOST_CONF"
capture 03-token profiles/worker/03-headless.sh check
for auth in deploy-keys token; do
  rm -rf "$H/git/.configs" "$H/.ssh/known_hosts"
  printf '%s\n' "git_auth=$auth" deploy_repos=configs=example/.configs > "$HOST_CONF"
  capture "preamble-$auth" profiles/worker/preamble-github-auth.sh install
done
echo "agent-defaults: $pass passed, $fail failed"
(( fail == 0 ))
