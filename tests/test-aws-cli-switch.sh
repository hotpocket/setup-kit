#!/bin/bash
# Every path selecting the AWS v2 bundle must agree about its switch, including
# apt planning: reinstalling worker.list's v1 after phase 07 removes it flaps.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
K="$TMP/kit"; BIN="$TMP/bin"
mkdir -p "$K" "$BIN"
cp -a "$KIT_DIR"/{lib.sh,profiles,components,manifests,verify.sh} "$K/"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" USER=fixture
export STATE="$TMP/state" CALLS="$TMP/calls" TMPDIR="$TMP/tmp"
export PATH="$BIN:/usr/bin:/bin" HOST_CONF="$TMP/host.conf" KIT_HOST_CONF="$TMP/host.conf"
export KIT_LOG_DIR="$TMP/logs" KIT_VERBOSE=1 GIT_CONFIG_SYSTEM="$TMP/gitconfig" GIT_CONFIG_GLOBAL=/dev/null
unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS KIT_RUN_LOG
cat > "$BIN/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$CALLS"
if [[ "$*" == 'apt-get remove -y awscli' ]]; then
  rm -f "$STATE/apt-v1"; : > "$STATE/version"
elif [[ "$1" == "$TMPDIR/"*/aws/install && "${2:-}" == --update && $# == 2 ]]; then
  exec "$@"
else exit 99; fi
SH
cat > "$BIN/aws" <<'SH'
#!/bin/bash
[[ "$*" == --version && -s "$STATE/version" ]] || exit 1
printf 'aws-cli/%s Linux fixture\n' "$(cat "$STATE/version")"
SH
cat > "$BIN/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CALLS"
[[ "$1" == -fsSL && "$2" == https://awscli.amazonaws.com/awscli-exe-linux-*.zip && "$3" == -o && "$4" == "$TMPDIR/"*/awscliv2.zip ]] || exit 99
printf 'inert zip fixture\n' > "$4"
SH
cat > "$BIN/unzip" <<'SH'
#!/bin/bash
[[ "$1" == -q && "$2" == "$TMPDIR/"*/awscliv2.zip && "$3" == -d && "$4" == "${2%/*}" ]] || exit 99
mkdir -p "$4/aws"
cat > "$4/aws/install" <<'INSTALL'
#!/bin/bash
[[ "$*" == --update ]] || exit 99
printf '2.32.30\n' > "$STATE/version"
touch "$STATE/bundle-installed"
INSTALL
chmod +x "$4/aws/install"
SH
cat > "$BIN/dpkg-query" <<'SH'
#!/bin/bash
[[ "${*: -1}" != awscli || -f "$STATE/apt-v1" ]] || exit 1
case "$*" in *'db:Status-Abbrev'*) exit 0 ;; *) echo 'install ok installed' ;; esac
SH
cat > "$BIN/dpkg" <<'SH'
#!/bin/bash
[[ "$*" == '-s awscli' && -f "$STATE/apt-v1" ]]
SH
for tool in lspci systemctl journalctl coredumpctl gh gcloud apt-cache; do
  printf '#!/bin/bash\nexit 0\n' > "$BIN/$tool"
done
printf '#!/bin/bash\necho fixture-host\n' > "$BIN/hostname"
chmod +x "$BIN"/*
reset() {
  rm -rf "$HOME" "$STATE" "$TMPDIR"
  mkdir -p "$HOME" "$STATE" "$TMPDIR"
  printf '[core]\nfsync=committed\nfsyncMethod=fsync\n' > "$GIT_CONFIG_SYSTEM"
  touch "$STATE/apt-v1"; printf '1.42.0\n' > "$STATE/version"
  conf group_dev_cloud=no
}
conf() {
  printf '%s\n' profile=worker headless=yes configs=no cond_nvidia=no cond_virtualbox=no \
    lang_python=no lang_node=no lang_flutter=no group_worker=no \
    tmp_on_disk=no component_resource_guards=no component_oom_zram=no component_uutils_ls=no \
    component_docker_rootless=skip component_herdr=no component_ollama=no component_t3code=no \
    component_codex=no component_git_hub=no component_whisper=no component_chatterbox=no \
    component_mtga=no component_dictation=no component_ocr=no component_tts=no component_clipboard=no \
    component_lid_ignore=no "$@" > "$HOST_CONF"
}
# RC is read by assertion expressions.
# shellcheck disable=SC2034
run() { : > "$CALLS"; bash "$K/$1" "${2:-check}" > "$TMP/out" 2>&1; RC=$?; }
phase() { run profiles/worker/07-components.sh "${1:-check}"; }
verify() { run verify.sh; }
apt_phase() { run profiles/worker/02-apt-install.sh; }
contains() { grep -Fq -- "$1" "$TMP/out"; }
assert() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; cat "$TMP/out"; return 1; fi; }
case_install_on() {
  conf group_dev_cloud=no component_aws_cli=yes; phase install
  assert 'component yes, cloud no: removes v1 and installs v2 bundle' \
    '(( RC == 0 )) && [[ ! -e "$STATE/apt-v1" && -f "$STATE/bundle-installed" && "$(cat "$STATE/version")" == 2.32.30 ]] && grep -q "^curl .*https://awscli.amazonaws.com/" "$CALLS"'
}
case_install_off() {
  conf group_dev_cloud=yes component_aws_cli=no; phase install
  assert 'component no, cloud yes: no AWS mutation or download' \
    '(( RC == 0 )) && [[ -e "$STATE/apt-v1" && ! -e "$STATE/bundle-installed" && ! -s "$CALLS" ]] && contains "aws-cli: disabled, skipping install and checks"'
}
case_default_on() {
  conf group_dev_cloud=yes; phase
  assert 'unset component inherits cloud yes' '(( RC == 0 )) && contains "aws-cli v2 missing"'
}
case_default_off() {
  conf group_dev_cloud=no; phase
  assert 'unset component inherits cloud no' '(( RC == 0 )) && ! contains "aws-cli v2 missing" && contains "aws-cli: disabled, skipping install and checks"'
}
case_verify_on_v1() {
  conf group_dev_cloud=no component_aws_cli=yes; verify
  assert 'verify requires v2 when component yes and cloud no' '(( RC != 0 )) && contains "FAIL  aws is v1.42.0" && contains "v2 required"'
}
case_verify_on_v2() {
  conf group_dev_cloud=no component_aws_cli=yes; echo 2.32.30 > "$STATE/version"; verify
  assert 'verify accepts v2 when component yes and cloud no' '(( RC == 0 )) && contains "PASS  aws-cli v2 present"'
}
case_verify_off() {
  conf group_dev_cloud=yes component_aws_cli=no; verify
  assert 'verify skips v2 when component no despite cloud yes' '(( RC == 0 )) && ! contains "FAIL  aws"'
}
case_verify_default_on() {
  conf group_dev_cloud=yes; verify
  assert 'verify unset component inherits cloud yes' '(( RC != 0 )) && contains "FAIL  aws is v1.42.0"'
}
case_verify_default_off() {
  conf group_dev_cloud=no; verify
  assert 'verify unset component inherits cloud no' '(( RC == 0 )) && ! contains "FAIL  aws"'
}
case_apt_on() {
  conf group_worker=yes group_dev_cloud=no component_aws_cli=yes
  rm "$STATE/apt-v1"; apt_phase
  assert 'apt phase does not request v1 when v2 selected' '(( RC == 0 )) && contains "wanted packages installed" && [[ ! -s "$CALLS" ]] && contains "AWS CLI v2 is selected, so the apt awscli v1 package is skipped to prevent reinstall and removal loops."'
}
case_apt_off() {
  conf group_worker=yes group_dev_cloud=no component_aws_cli=no
  rm "$STATE/apt-v1"; apt_phase
  assert 'apt phase retains worker v1 when v2 disabled' '(( RC == 0 )) && grep -qx "  awscli" "$TMP/out"'
}
case_apt_default_on() {
  conf group_worker=yes group_dev_cloud=yes; rm "$STATE/apt-v1"; apt_phase
  assert 'apt phase excludes v1 when v2 inherits cloud yes' '(( RC == 0 )) && contains "wanted packages installed"'
}
case_verify_apt_on() {
  conf group_worker=yes group_dev_cloud=no component_aws_cli=yes
  rm "$STATE/apt-v1"; echo 2.32.30 > "$STATE/version"; verify
  assert 'verify does not require apt v1 when worker selects v2' '(( RC == 0 )) && contains "PASS  aws-cli v2 present" && ! contains "FAIL  apt: awscli"'
}
case_verify_apt_off() {
  conf group_worker=yes group_dev_cloud=no component_aws_cli=no
  rm "$STATE/apt-v1"; verify
  assert 'verify still requires worker apt v1 when v2 disabled' '(( RC != 0 )) && contains "FAIL  apt: awscli" && ! contains "FAIL  aws is"'
}
case_converges() {
  conf group_worker=yes group_dev_cloud=no component_aws_cli=yes; phase install
  apt_phase
  assert 'v2 install followed by apt pass stays converged' '(( RC == 0 )) && contains "wanted packages installed" && [[ ! -e "$STATE/apt-v1" ]]' || return 1
  phase install
  assert 'second component install performs no AWS actions' '(( RC == 0 )) && [[ ! -s "$CALLS" ]] && contains "aws-cli v2.32.30"'
}
pass=0; fail=0
for name in install_on install_off default_on default_off verify_on_v1 verify_on_v2 verify_off verify_default_on verify_default_off apt_on apt_off apt_default_on verify_apt_on verify_apt_off converges; do
  [[ -z "${1:-}" || "$name" == "$1" ]] || continue
  reset
  if "case_$name"; then ((pass++)); else ((fail++)); fi
done
echo "aws-cli-switch: $pass passed, $fail failed"
(( fail == 0 ))
