#!/bin/bash
# Every unattended Git writer needs system fsync policy, including bare hubs.
# Exercise both real identity phases and the full independent verifier. All
# configs, logs and privileged-command fixtures stay in this private directory.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
K="$TMP/kit"; BIN="$TMP/bin"
mkdir -p "$K" "$BIN"
cp -a "$KIT_DIR"/{lib.sh,profiles,components,manifests,verify.sh} "$K/"
export HOME="$TMP/home" USER=fixture PATH="$BIN:/usr/bin:/bin"
export HOST_CONF="$TMP/host.conf" KIT_HOST_CONF="$TMP/host.conf"
export KIT_LOG_DIR="$TMP/logs" KIT_VERBOSE=1 CALLS="$TMP/calls"
export GIT_CONFIG_SYSTEM="$TMP/gitconfig" GIT_CONFIG_GLOBAL="$TMP/global"
unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS KIT_RUN_LOG
cat > "$BIN/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
[[ "$1" == git && "$2" == config && "$3" == --system ]] || exit 99
[[ "$GIT_CONFIG_SYSTEM" == "${HOME%/*}/gitconfig" ]] || exit 98
[[ "${FSYNC_WRITE_FAIL:-0}" == 0 ]] || exit 1
exec "$@"
SH
cat > "$BIN/timedatectl" <<'SH'
#!/bin/bash
[[ "$*" == 'show -p Timezone --value' ]] && echo America/Los_Angeles
SH
cat > "$BIN/locale" <<'SH'
#!/bin/bash
[[ "$*" == -a ]] && echo en_US.utf8
SH
printf '#!/bin/bash\necho none\n' > "$BIN/systemd-detect-virt"
printf '#!/bin/bash\nexit 2\n' > "$BIN/getent"
printf '#!/bin/bash\necho fixture-host\n' > "$BIN/hostname"
for tool in lspci systemctl journalctl coredumpctl dpkg gh; do
  printf '#!/bin/bash\nexit 0\n' > "$BIN/$tool"
done
chmod +x "$BIN"/*
reset() {
  rm -f "$GIT_CONFIG_SYSTEM" "$GIT_CONFIG_SYSTEM.lock" "$TMP/before"
  rm -rf "$HOME" "$TMP/xdg" "$TMP/hub with spaces"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$TMP/global" XDG_CONFIG_HOME="$TMP/xdg"
  unset GIT_CONFIG_NOSYSTEM
  printf '%s\n' profile=workstation headless=yes configs=no cond_nvidia=no \
    lang_python=no lang_node=no lang_flutter=no component_oom_zram=no \
    component_resource_guards=no component_clipboard=no tmp_on_disk=no > "$HOST_CONF"
  # Correct user values must never hide missing or wrong SYSTEM values.
  printf '[core]\n\tfsync = committed\n\tfsyncMethod = fsync\n' > "$GIT_CONFIG_GLOBAL"
  : > "$CALLS"; : > "$TMP/out"
  PROFILE=workstation; FSYNC_WRITE_FAIL=0; export FSYNC_WRITE_FAIL
}
seed() { printf '[core]\n\tfsync = committed\n\tfsyncMethod = fsync\n' > "$GIT_CONFIG_SYSTEM"; }
# RC and before are read by assertion expressions below.
# shellcheck disable=SC2034
phase() { bash "$K/profiles/$PROFILE/00-identity.sh" "${1:-install}" > "$TMP/out" 2>&1; RC=$?; }
# shellcheck disable=SC2034
verify() { bash "$K/verify.sh" > "$TMP/out" 2>&1; RC=$?; }
get() { git config --system --get "$1"; }
same() { cmp -s "$TMP/before" "$GIT_CONFIG_SYSTEM"; }
contains() { grep -Fq -- "$1" "$TMP/out"; }
assert() {
  if eval "$2"; then echo "  ok   $1"
  else echo "  FAIL $1"; cat "$TMP/out"; return 1; fi
}
case_fresh_fsync() {
  phase
  assert 'fresh: system core.fsync=committed' '(( RC == 0 )) && [[ "$(get core.fsync)" == committed ]]'
}
case_fresh_method() {
  phase
  assert 'fresh: system core.fsyncMethod=fsync' '(( RC == 0 )) && [[ "$(get core.fsyncMethod)" == fsync ]]'
}
case_preserve() {
  printf '[receive]\n\tdenyNonFastForwards = true\n[core]\n\tfsync = none\n' > "$GIT_CONFIG_SYSTEM"
  cp "$GIT_CONFIG_SYSTEM" "$TMP/expected"
  git config --file "$TMP/expected" core.fsync committed
  git config --file "$TMP/expected" core.fsyncMethod fsync
  phase
  assert 'reconcile preserves unrelated system settings' '(( RC == 0 )) && cmp -s "$TMP/expected" "$GIT_CONFIG_SYSTEM"'
}
case_unchanged() {
  seed; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"
  local before
  # shellcheck disable=SC2034
  before=$(stat -c '%i:%s:%Y:%Z:%a' "$GIT_CONFIG_SYSTEM")
  phase
  assert 'already correct: no write, reports nothing to change' \
    '(( RC == 0 )) && same && [[ "$before" == "$(stat -c '\''%i:%s:%Y:%Z:%a'\'' "$GIT_CONFIG_SYSTEM")" && ! -s "$CALLS" ]] && contains "git fsync: system settings already correct; nothing to change"'
}
case_wrong_fsync() {
  seed; git config --system core.fsync none; phase
  assert 'wrong core.fsync corrected' '(( RC == 0 )) && [[ "$(get core.fsync)" == committed ]]'
}
case_wrong_method() {
  seed; git config --system core.fsyncMethod writeout-only; phase
  assert 'wrong core.fsyncMethod corrected' '(( RC == 0 )) && [[ "$(get core.fsyncMethod)" == fsync ]]'
}
case_check_missing() {
  phase check
  assert 'check: both missing keys reported, no config or sudo writes' \
    '(( RC == 0 )) && [[ ! -e "$GIT_CONFIG_SYSTEM" && ! -s "$CALLS" ]] && contains "[WARN]  git fsync: system core.fsync missing or different" && contains "[WARN]  git fsync: system core.fsyncMethod missing or different"'
}
case_check_wrong() {
  seed; git config --system core.fsync none; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; phase check
  assert 'check: drift reported without repair' '(( RC == 0 )) && same && [[ ! -s "$CALLS" ]] && contains "[WARN]  git fsync: system core.fsync missing or different"'
}
case_worker() {
  PROFILE=worker; printf '\nprofile=worker\n' >> "$HOST_CONF"; phase
  assert 'worker default: both system keys set through shared phase' \
    '(( RC == 0 )) && [[ "$(get core.fsync)" == committed && "$(get core.fsyncMethod)" == fsync ]]'
}
case_write_failure() {
  FSYNC_WRITE_FAIL=1; phase
  assert 'failed system write fails phase and names repair' \
    '(( RC != 0 )) && [[ ! -e "$GIT_CONFIG_SYSTEM" ]] && contains "[FAIL]  git fsync: cannot set system core.fsync; rerun install with working sudo"'
}
case_verify_missing_fsync() {
  seed; git config --system --unset core.fsync; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; verify
  assert 'verify: missing system core.fsync fails despite correct user setting' \
    '(( RC != 0 )) && same && contains "FAIL  git fsync: system core.fsync must be committed" && [[ "$(grep -c '\''^FAIL '\'' "$TMP/out")" == 1 && "$(cat "$CALLS")" == "-n true" ]]'
}
case_verify_missing_method() {
  seed; git config --system --unset core.fsyncMethod; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; verify
  assert 'verify: missing system core.fsyncMethod fails despite correct user setting' \
    '(( RC != 0 )) && same && contains "FAIL  git fsync: system core.fsyncMethod must be fsync" && [[ "$(grep -c '\''^FAIL '\'' "$TMP/out")" == 1 ]]'
}
case_verify_wrong_fsync() {
  seed; git config --system core.fsync none; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; verify
  assert 'verify: wrong system core.fsync fails without repair' \
    '(( RC != 0 )) && same && contains "FAIL  git fsync: system core.fsync must be committed" && [[ "$(grep -c '\''^FAIL '\'' "$TMP/out")" == 1 ]]'
}
case_verify_wrong_method() {
  seed; git config --system core.fsyncMethod writeout-only; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; verify
  assert 'verify: wrong system core.fsyncMethod fails without repair' \
    '(( RC != 0 )) && same && contains "FAIL  git fsync: system core.fsyncMethod must be fsync" && [[ "$(grep -c '\''^FAIL '\'' "$TMP/out")" == 1 ]]'
}
case_verify_correct() {
  seed; cp "$GIT_CONFIG_SYSTEM" "$TMP/before"; verify
  assert 'verify: correct system policy passes without writes' \
    '(( RC == 0 )) && same && contains "PASS  git fsync: system core.fsync=committed" && contains "PASS  git fsync: system core.fsyncMethod=fsync" && [[ "$(cat "$CALLS")" == "-n true" ]]'
}
case_global_fsync() {
  seed; git config --global core.fsync none; verify
  assert 'F1 verify: global fsync override fails with its origin' \
    '(( RC != 0 )) && contains "FAIL  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL" && [[ "$(git config --global core.fsync)" == none ]]'
}
case_global_method() {
  seed; git config --global core.fsyncMethod writeout-only; verify
  assert 'F1 verify: global method override fails with its origin' \
    '(( RC != 0 )) && contains "FAIL  git fsync: invoking user core.fsyncMethod" && contains "file:$GIT_CONFIG_GLOBAL"'
}
case_doctor_global_fsync() {
  seed; git config --global core.fsync none; phase check
  assert 'F1 doctor: global fsync override fails, identity still runs' \
    '(( RC != 0 )) && contains "[FAIL]  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL" && contains "timezone America/Los_Angeles" && [[ ! -s "$CALLS" ]]'
}
case_doctor_global_method() {
  seed; git config --global core.fsyncMethod batch; phase check
  assert 'F1 doctor: global method override fails with its origin' \
    '(( RC != 0 )) && contains "[FAIL]  git fsync: invoking user core.fsyncMethod" && contains "file:$GIT_CONFIG_GLOBAL" && [[ ! -s "$CALLS" ]]'
}
case_xdg_override() {
  seed; unset GIT_CONFIG_GLOBAL; mkdir -p "$XDG_CONFIG_HOME/git"
  printf '[core]\nfsync=none\n' > "$XDG_CONFIG_HOME/git/config"; verify
  assert 'F1 verify: XDG override fails with its origin' \
    '(( RC != 0 )) && contains "FAIL  git fsync: invoking user core.fsync" && contains "file:$XDG_CONFIG_HOME/git/config"'
}
hub() {
  seed; mkdir -p "$TMP/hub with spaces"
  git init -q --bare "$TMP/hub with spaces/source.git"
  printf '\ncomponent_git_hub=yes\ngit_hub_root="%s"\ngit_hub_repos="acme/source:nested/clone"\n' "$TMP/hub with spaces" >> "$HOST_CONF"
}
case_local_fsync() {
  hub; git --git-dir="$TMP/hub with spaces/source.git" config core.fsync none; verify
  assert 'F1 verify: managed bare repo local fsync override fails with origin' \
    '(( RC != 0 )) && contains "FAIL  git fsync: hub source.git core.fsync" && contains "file:$TMP/hub with spaces/source.git/config" && [[ "$(git --git-dir="$TMP/hub with spaces/source.git" config --local core.fsync)" == none ]]'
}
case_local_method() {
  hub; git --git-dir="$TMP/hub with spaces/source.git" config core.fsyncMethod writeout-only; verify
  assert 'F1 verify: managed bare repo local method override fails' \
    '(( RC != 0 )) && contains "FAIL  git fsync: hub source.git core.fsyncMethod" && contains "file:$TMP/hub with spaces/source.git/config"'
}
case_doctor_local() {
  hub; git --git-dir="$TMP/hub with spaces/source.git" config core.fsync none; phase check
  assert 'F1 doctor: managed bare repo local override fails without repair' \
    '(( RC != 0 )) && contains "[FAIL]  git fsync: hub source.git core.fsync" && contains "file:$TMP/hub with spaces/source.git/config" && [[ ! -s "$CALLS" ]]'
}
case_local_include() {
  hub; printf '[core]\nfsync=objects\n' > "$TMP/repo policy.inc"
  git --git-dir="$TMP/hub with spaces/source.git" config include.path "$TMP/repo policy.inc"; verify
  assert 'F1 verify: managed repo include weakening coverage reports included origin' \
    '(( RC != 0 )) && contains "FAIL  git fsync: hub source.git core.fsync" && contains "file:$TMP/repo policy.inc"'
}
case_hub_correct() {
  hub; verify
  assert 'F1 verify: managed bare repo inherits correct policy' \
    '(( RC == 0 )) && contains "PASS  git fsync: hub source.git core.fsync" && contains "PASS  git fsync: hub source.git core.fsyncMethod"'
}
case_hub_disabled() {
  hub; git --git-dir="$TMP/hub with spaces/source.git" config core.fsync none
  printf '\ncomponent_git_hub=no\n' >> "$HOST_CONF"; verify
  assert 'F1 verify: disabled hub is outside managed-repo checks, scope reported' \
    '(( RC == 0 )) && ! contains "hub source.git core.fsync" && contains "other repositories local overrides are outside this check"'
}
case_weak_coverage() {
  seed
  local value
  for value in objects pack 'loose-object,pack' 'pack,reference' '-committed' 'none,loose-object'; do
    [[ -z "${FSYNC_COVERAGE_ONLY:-}" || "$value" == "$FSYNC_COVERAGE_ONLY" ]] || continue
    git config --global core.fsync "$value"; verify
    assert "F1 verify: incomplete committed coverage rejected ($value)" \
      '(( RC != 0 )) && contains "FAIL  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL"' || return 1
    phase check
    assert "F1 doctor: incomplete committed coverage rejected ($value)" \
      '(( RC != 0 )) && contains "[FAIL]  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL"' || return 1
  done
}
case_strong_coverage() {
  seed
  local value
  for value in committed added all 'loose-object,pack,reference' 'objects,reference' 'none,loose-object,pack,reference' 'loose-object,reference' 'committed,-loose-object'; do
    [[ -z "${FSYNC_COVERAGE_ONLY:-}" || "$value" == "$FSYNC_COVERAGE_ONLY" ]] || continue
    git config --global core.fsync "$value"; verify
    assert "F1 verify: full committed coverage accepted ($value)" \
      '(( RC == 0 )) && contains "PASS  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL"' || return 1
    phase check
    assert "F1 doctor: full committed coverage accepted ($value)" \
      '(( RC == 0 )) && contains "[ OK ]  git fsync: invoking user core.fsync" && contains "file:$GIT_CONFIG_GLOBAL"' || return 1
  done
}
include_policy() {
  seed
  printf '[core]\n%s = %s\n' "$1" "$2" > "$TMP/system policy.inc"
  git config --system "core.$1" "$2"
  git config --system include.path "$TMP/system policy.inc"
  cp "$GIT_CONFIG_SYSTEM" "$TMP/before"
  cp "$TMP/system policy.inc" "$TMP/include.before"
}
case_include_install() {
  include_policy fsync none
  printf '\ngit_user_name=Fixture\ngit_user_email=fixture@example.invalid\n' >> "$HOST_CONF"
  phase install
  assert 'F2 install: conflicting trailing include named, files untouched, identity completed' \
    '(( RC != 0 )) && same && cmp -s "$TMP/include.before" "$TMP/system policy.inc" && [[ ! -s "$CALLS" && "$(git config --global user.name)" == Fixture ]] && contains "system policy.inc" && contains "set core.fsync=committed there" && contains "timezone America/Los_Angeles"'
}
case_include_check() {
  include_policy fsync none; phase check
  assert 'F2 doctor: conflicting system include fails without skipping identity' \
    '(( RC != 0 )) && same && [[ ! -s "$CALLS" ]] && contains "system policy.inc" && contains "set core.fsync=committed there" && contains "timezone America/Los_Angeles"'
}
case_include_method() {
  include_policy fsyncMethod writeout-only; phase install
  assert 'F2 install: conflicting included method named without main-file rewrite' \
    '(( RC != 0 )) && same && [[ ! -s "$CALLS" ]] && contains "system policy.inc" && contains "set core.fsyncMethod=fsync there" && contains "timezone America/Los_Angeles"'
}
case_include_correct() {
  include_policy fsync committed; phase install
  assert 'F2 install: correct included system setting accepted unchanged' \
    '(( RC == 0 )) && same && [[ ! -s "$CALLS" ]] && contains "system settings already correct; nothing to change"'
}
pass=0; fail=0
for name in fresh_fsync fresh_method preserve unchanged wrong_fsync wrong_method check_missing check_wrong worker write_failure verify_missing_fsync verify_missing_method verify_wrong_fsync verify_wrong_method verify_correct global_fsync global_method doctor_global_fsync doctor_global_method xdg_override local_fsync local_method doctor_local local_include hub_correct hub_disabled weak_coverage strong_coverage include_install include_check include_method include_correct; do
  [[ -z "${1:-}" || "$name" == "$1" ]] || continue
  reset
  if "case_$name"; then ((pass++)); else ((fail++)); fi
done
echo "git-fsync: $pass passed, $fail failed"
(( fail == 0 ))
