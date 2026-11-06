# shellcheck shell=bash disable=SC2034
# Class: reviewer gate access without a review thread must leave delivery off.
# Exercise the profile's check/install seam with stateful fake user units.
GN="$TMP/gate-setup"; GN_HOME="$GN/home"; GN_STATE="$GN/state"
GN_CONF="$GN/host.conf"; GN_UD="$GN_HOME/.config/systemd/user"
mkdir -p "$GN/bin" "$GN_HOME" "$GN_STATE" "$GN/system/proc"
printf 'MemTotal: 33554432 kB\n' > "$GN/system/proc/meminfo"
cp "$TMP/bin/sudo" "$GN/bin/sudo"
cat > "$GN/bin/systemctl" <<'SH'
#!/bin/bash
echo "$*" >> "$GN/systemctl.calls"
case "$*" in
  '--user is-enabled -q git-hub-relay.timer') [[ -f "$GN_STATE/enabled" ]];;
  '--user is-active -q git-hub-relay.timer') [[ -f "$GN_STATE/active" ]];;
  '--user enable --now git-hub-relay.timer') touch "$GN_STATE/enabled" "$GN_STATE/active";;
  '--user disable --now git-hub-relay.timer') rm -f "$GN_STATE/enabled" "$GN_STATE/active";;
  *) exit 0;;
esac
SH
cat > "$GN/bin/loginctl" <<'SH'
#!/bin/bash
echo "$*" >> "$GN/loginctl.calls"
case "$1" in
  show-user) [[ -f "$GN_STATE/linger" ]] && echo yes || echo no;;
  enable-linger) touch "$GN_STATE/linger";;
esac
SH
chmod +x "$GN/bin/"*
gnconf() {
  printf '%s\n' profile=workstation configs=no tmp_on_disk=no component_resource_guards=no group_dev_cloud=no \
    component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
    component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
    component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no \
    component_chatterbox=no component_clipboard=no component_git_hub=no git_hub_gate=control.lan "$@" > "$GN_CONF"
}
gnrun() {
  : > "$GN/systemctl.calls"; : > "$GN/loginctl.calls"
  env GN="$GN" GN_STATE="$GN_STATE" PATH="$GN/bin:$TMP/bin:/usr/bin:/bin" HOME="$GN_HOME" \
    GIT_HOME="$GN/clones" HOST_CONF="$GN_CONF" KIT_LOG_DIR="$GN/logs" KIT_QUIET=0 \
    KIT_MEMORY_ROOT="$GN/system" KIT_GIT_HUB_SYSTEM_ROOT="$GN/system" \
    bash "$KIT_DIR/profiles/workstation/07-components.sh" "$1" > "$TMP/out" 2>&1
  GN_RC=$?
}
gnstate() {
  { find "$GN_HOME" "$GN_STATE" -printf '%p %y %m %l\n' | sort
    find "$GN_HOME" "$GN_STATE" -type f -exec sha256sum {} + | sort
  } | sha256sum
}
gnquiet() { ! grep -Eq -- '--user (enable|disable|stop|start|restart|daemon-reload)' "$GN/systemctl.calls"; }

gnconf; gnrun install
assert 'GN1. gate without a thread installs key alias and CLI without relay or linger' \
  '(( GN_RC == 0 )) && [[ -s "$GN_HOME/.ssh/git_hub_gate" && -s "$GN_HOME/.ssh/git_hub_gate.pub" && -L "$GN_HOME/.local/bin/git-hub" && ! -e "$GN_UD/git-hub-relay.timer" && ! -e "$GN_UD/git-hub-relay.service" && ! -e "$GN_STATE/enabled" && ! -e "$GN_STATE/active" && ! -e "$GN_STATE/linger" ]] && grep -q "HostName control.lan" "$GN_HOME/.ssh/config" && grep -q "IdentityAgent none" "$GN_HOME/.ssh/config" && grep -q "relay off: no git_hub_review_thread" "$TMP/out" && gnquiet'
GN_ACCESS=$(sha256sum "$GN_HOME/.ssh/git_hub_gate" "$GN_HOME/.ssh/git_hub_gate.pub" "$GN_HOME/.ssh/config")
# Reset relay-only fixture state so GN2 is independent of a failed GN1.
rm -f "$GN_UD/git-hub-relay.timer" "$GN_UD/git-hub-relay.service" "$GN_STATE/enabled" "$GN_STATE/active" "$GN_STATE/linger"
gnconf git_hub_review_thread=beast-vm:reviews; gnrun install
assert 'GN2. a configured thread enables relay and linger without changing gate access' \
  '(( GN_RC == 0 )) && [[ -f "$GN_UD/git-hub-relay.timer" && -f "$GN_UD/git-hub-relay.service" && -f "$GN_STATE/enabled" && -f "$GN_STATE/active" && -f "$GN_STATE/linger" && "$(sha256sum "$GN_HOME/.ssh/git_hub_gate" "$GN_HOME/.ssh/git_hub_gate.pub" "$GN_HOME/.ssh/config")" == "$GN_ACCESS" ]] && grep -qx -- "--user enable --now git-hub-relay.timer" "$GN/systemctl.calls"'
GN_FILES=$(sha256sum "$GN_UD/git-hub-relay.timer" "$GN_UD/git-hub-relay.service")
gnconf; GN_BEFORE=$(gnstate); gnrun check
assert 'GN3. check reports an enabled relay with no thread as drift and changes nothing' \
  '(( GN_RC == 0 )) && [[ "$(gnstate)" == "$GN_BEFORE" && -f "$GN_STATE/enabled" && -f "$GN_STATE/active" ]] && grep -q "WARN.*git-hub-relay.timer.*git_hub_review_thread" "$TMP/out" && gnquiet'
gnrun install
assert 'GN4. removing the thread disables and stops the old timer while retaining units and access' \
  '(( GN_RC == 0 )) && [[ ! -e "$GN_STATE/enabled" && ! -e "$GN_STATE/active" && "$(sha256sum "$GN_UD/git-hub-relay.timer" "$GN_UD/git-hub-relay.service")" == "$GN_FILES" && "$(sha256sum "$GN_HOME/.ssh/git_hub_gate" "$GN_HOME/.ssh/git_hub_gate.pub" "$GN_HOME/.ssh/config")" == "$GN_ACCESS" && -L "$GN_HOME/.local/bin/git-hub" ]] && grep -qx -- "--user disable --now git-hub-relay.timer" "$GN/systemctl.calls" && grep -q "git-hub-relay.timer disabled and stopped" "$TMP/out" && grep -q "relay off: no git_hub_review_thread" "$TMP/out" && ! grep -q -- "--user enable" "$GN/systemctl.calls"'
rm -f "$GN_STATE/enabled" "$GN_STATE/active"
GN_BEFORE=$(gnstate); gnrun check
assert 'GN5. disabled inactive retained unit files are current in check mode' \
  '(( GN_RC == 0 )) && [[ "$(gnstate)" == "$GN_BEFORE" ]] && grep -q "relay off: no git_hub_review_thread" "$TMP/out" && ! grep -q "WARN.*git-hub-relay" "$TMP/out" && gnquiet'

touch "$GN_STATE/enabled"; gnrun install
assert 'GN6. relay off disables an enabled timer even when it is already inactive' \
  '(( GN_RC == 0 )) && [[ ! -e "$GN_STATE/enabled" && ! -e "$GN_STATE/active" ]] && grep -qx -- "--user disable --now git-hub-relay.timer" "$GN/systemctl.calls"'
rm -f "$GN_STATE/enabled" "$GN_STATE/active"
touch "$GN_STATE/active"; gnrun install
assert 'GN7. relay off stops a running timer even when it is already disabled' \
  '(( GN_RC == 0 )) && [[ ! -e "$GN_STATE/enabled" && ! -e "$GN_STATE/active" ]] && grep -qx -- "--user disable --now git-hub-relay.timer" "$GN/systemctl.calls"'
