#!/bin/bash
# git_user_name / git_user_email in the host conf: phase 00 sets the global git
# author on a box that has no .configs .gitconfig (the agent role). Unset keys
# change nothing; a value already set to something else is reported, never
# overwritten; ~/.gitconfig linked into .configs is never written through.
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; BIN="$TMP/bin"; mkdir -p "$H" "$BIN"
export HOME="$H" HOST_CONF="$TMP/host.conf" PATH="$BIN:/usr/bin:/bin" USER=agents
# Confine every write: logs, XDG and git's global file all live under $TMP.
export KIT_LOG_DIR="$TMP/logs" XDG_CONFIG_HOME="$H/.config" GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL KIT_RUN_LOG
for c in timedatectl systemd-detect-virt sudo dpkg locale-gen update-locale; do
  printf '#!/bin/bash\ncase "$*" in "show -p Timezone --value") echo America/Los_Angeles ;; esac\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"
done
printf '#!/bin/bash\n[[ "$1" == -a ]] && echo en_US.utf8\nexit 0\n' > "$BIN/locale"; chmod +x "$BIN/locale"
printf '#!/bin/bash\nexit 2\n' > "$BIN/getent"; chmod +x "$BIN/getent"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out" | tail -8; fi; }
run() { bash "$KIT_DIR/profiles/workstation/00-identity.sh" "${1:-install}" > "$TMP/out" 2>&1; rc=$?; }
conf() { printf '%s\n' "$@" > "$HOST_CONF"; }
fresh() { rm -rf "$H"; mkdir -p "$H"; }
gget() { git config --global --get "$1"; }

fresh; conf timezone=America/Los_Angeles; run
assert 'unset keys: no ~/.gitconfig written' '[[ $rc == 0 && ! -e "$H/.gitconfig" ]]'

fresh; conf 'git_user_name=hotpocket' 'git_user_email=agent@example.invalid'; run check
assert 'check reports the missing identity and writes nothing' '[[ ! -e "$H/.gitconfig" ]] && grep -q "git author.*not set" "$TMP/out"'

fresh; conf 'git_user_name=hotpocket' 'git_user_email=agent@example.invalid  # a comment'; run
assert 'install sets name and email' '[[ "$(gget user.name)" == hotpocket && "$(gget user.email)" == agent@example.invalid ]]'
assert 'the file is a real file, not a link' '[[ -f "$H/.gitconfig" && ! -L "$H/.gitconfig" ]]'
cp "$H/.gitconfig" "$TMP/before"; run
assert 'second install changes nothing and says ok' 'cmp -s "$TMP/before" "$H/.gitconfig" && grep -q "git author hotpocket" "$TMP/out"'

fresh; git config --global user.name hotpocket; git config --global user.email other@example.invalid; conf 'git_user_name=hotpocket' 'git_user_email=agent@example.invalid'; run
assert 'a different existing email is reported, not overwritten' '[[ "$(gget user.email)" == other@example.invalid ]] && grep -q "WARN.*git author: user.email is" "$TMP/out"'

fresh; printf '[user]\n  name = hotpocket\n  email = included@example.invalid\n' > "$H/author.inc"; printf '[include]\n  path = author.inc\n' > "$H/.gitconfig"
cp "$H/.gitconfig" "$TMP/gc.before"; cp "$H/author.inc" "$TMP/inc.before"
conf 'git_user_name=hotpocket' 'git_user_email=agent@example.invalid'; run
assert 'an included author counts as existing: reported, both files untouched' 'cmp -s "$TMP/gc.before" "$H/.gitconfig" && cmp -s "$TMP/inc.before" "$H/author.inc" && grep -q "WARN.*git author: user.email is" "$TMP/out"'

fresh; mkdir -p "$TMP/configs"; printf '[user]\n  name = someone\n' > "$TMP/configs/.gitconfig"; ln -s "$TMP/configs/.gitconfig" "$H/.gitconfig"
cp "$TMP/configs/.gitconfig" "$TMP/link.before"
conf 'git_user_name=hotpocket' 'git_user_email=agent@example.invalid'; run
assert 'a linked ~/.gitconfig is never written through' '[[ -L "$H/.gitconfig" && "$(readlink "$H/.gitconfig")" == "$TMP/configs/.gitconfig" ]] && cmp -s "$TMP/link.before" "$TMP/configs/.gitconfig" && grep -q "WARN.*linked" "$TMP/out"'

# The caller's own git config is never touched (sentinel outside the fake HOME).
if [[ "${1:-}" != --inner-only ]]; then
  printf '[user]\n  email = outer@example.invalid\n' > "$TMP/outer.gitconfig"; cp "$TMP/outer.gitconfig" "$TMP/outer.before"
  ( export GIT_CONFIG_GLOBAL="$TMP/outer.gitconfig"; bash "$0" --inner-only >/dev/null 2>&1 ) || true
  assert 'the suite leaves an outer global git config intact' 'cmp -s "$TMP/outer.before" "$TMP/outer.gitconfig"'
fi

echo "git-identity: $pass passed, $fail failed"
(( fail == 0 ))
