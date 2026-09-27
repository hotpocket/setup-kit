#!/bin/bash
# Calibration for the git hub (components/git-hub.md): a worker pushes to bare
# repos on a hub the human controls; the human forwards to GitHub and deploys.
#
# Real git throughout. The hub runs as the invoking user under a tmp root
# (git_hub_user=$(id -un)), sudo is a stub that runs file/git work and records
# account/ownership changes, and ssh is a stub that does what the hub's
# git-shell does: run the requested git-*-pack inside the hub root.
#
# Contract:
#   H. hub (07-components): opt-in; check creates nothing; install makes bare
#      repos that refuse rewrites and deletions, one hook dir, the upstream
#      recorded, pushers rendered with `restrict`; a second install is a no-op;
#      a changed pushers file is drift, reconciled by content.
#   P. pushes into the hub: fast-forward accepted and logged as JSON; forced
#      non-fast-forward refused; branch deletion refused.
#   W. worker (03-headless §8): off when git_hub is unset; check changes nothing;
#      install writes key + alias + re-points origin (old URL kept as `github`)
#      and the probe reaches the hub; idempotent; CHANGING git_hub moves only the
#      alias's HostName — the remote URLs stay put (the durability claim).
#   C. git-hub CLI: status names unforwarded branches; forward pushes to the
#      upstream and clears them; stage refuses a dirty clone, fast-forwards a
#      clean one and PRINTS the deploy command without running it.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out" | grep -i 'hub\|git' | head -30; fi; }
ME="$(id -un)"; BIN="$TMP/bin"; mkdir -p "$BIN"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1
ROOT="$TMP/srv"                     # the hub's git_hub_root
GH="$TMP/github"                    # stands in for GitHub: file:// upstream base
mkdir -p "$GH/acme"; git init -q --bare "$GH/acme/books.git"; git init -q --bare "$GH/acme/wbt.git"

# sudo stub: run file/git work as ourselves; RECORD account and ownership changes
cat > "$BIN/sudo" <<'S'
#!/bin/bash
[[ "$1" == -u ]] && shift 2
case "$1" in
  useradd|usermod|chown|chsh|groupadd|gpasswd) echo "SUDO $*" >> "$TMP/sudo.calls" ;;
  *) exec "$@" ;;
esac
S
# ssh stub = the hub's git-shell: last arg is "git-xxx-pack 'repo.git'", run in the hub root
cat > "$BIN/ssh" <<'S'
#!/bin/bash
echo "SSH $*" >> "$TMP/ssh.calls"
cmd="${@: -1}"
case "$cmd" in git-upload-pack*|git-receive-pack*) cd "$ROOT" && eval "exec $cmd" ;; esac
exit 128
S
for s in systemctl loginctl lspci nvidia-smi; do
  printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; is-enabled|is-active) exit 0;; esac\nexit 0\n' > "$BIN/$s"
done
printf '#!/bin/bash\necho "arn:aws:iam::1:user/pub"\n' > "$BIN/aws"
chmod +x "$BIN"/*
export TMP ROOT

# ---------------------------------------------------------------- H. hub side
HH="$TMP/hubhome"; mkdir -p "$HH"
PUSHERS="$TMP/pushers"
printf '# ai-3090\nssh-ed25519 AAAAC3NzaKEYONE ai@ai-3090\n\nfrom="10.0.0.9" ssh-ed25519 AAAAC3NzaKEYTWO ctl\n' > "$PUSHERS"
hubconf() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
  component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no component_chatterbox=no \
  "$@" > "$TMP/hub.conf"; }
HUBON=(component_git_hub=yes "git_hub_root=$ROOT" "git_hub_user=$ME" "git_hub_pushers=$PUSHERS"
       "git_hub_repos=acme/books:site/books acme/wbt" "git_hub_upstream_base=file://$GH/"
       "git_hub_deploy=books=scripts/deploy-site.sh")
run07() { PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$TMP/hub.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
cfg() { git --git-dir="$ROOT/$1.git" config --get "$2"; }

hubconf; run07
assert "H1. flag unset: opt-in, off by name, nothing created" \
  'grep -q "git-hub: opt-in" "$TMP/out" && [[ ! -e "$ROOT" ]]'
hubconf "${HUBON[@]}"; run07
assert "H2. yes, check: warns each missing bare repo, creates nothing" \
  'grep -q "WARN.*bare repo books.git missing" "$TMP/out" && grep -q "WARN.*bare repo wbt.git missing" "$TMP/out" && [[ ! -e "$ROOT/books.git" ]]'
MODE=install run07
assert "H3a. install: bare repos that refuse rewrites, deletions and bad objects" \
  '[[ "$(cfg books core.bare)" == true && "$(cfg books receive.denyNonFastForwards)" == true && "$(cfg books receive.denyDeletes)" == true && "$(cfg wbt receive.fsckObjects)" == true ]]'
assert "H3b. install: one hook dir, upstream recorded per repo" \
  '[[ "$(cfg books core.hooksPath)" == "$ROOT/.hooks" && -x "$ROOT/.hooks/post-receive" && "$(cfg books hub.upstream)" == "file://$GH/acme/books.git" && "$(cfg wbt hub.upstream)" == "file://$GH/acme/wbt.git" ]]'
AK="$ROOT/.ssh/authorized_keys"
assert "H3c. pushers rendered with restrict (options kept), comments/blanks dropped" \
  '[[ "$(cat "$AK")" == "$(printf "restrict ssh-ed25519 AAAAC3NzaKEYONE ai@ai-3090\nrestrict,from=\"10.0.0.9\" ssh-ed25519 AAAAC3NzaKEYTWO ctl")" ]]'
before="$(md5sum < "$AK")"; MODE=install run07
assert "H4. second install: no warnings for git-hub, authorized_keys byte-identical" \
  '! grep -q "WARN.*\(bare repo\|pushers\|hooks\)" "$TMP/out" && [[ "$(md5sum < "$AK")" == "$before" ]]'
sed -i '/KEYTWO/d' "$PUSHERS"; run07
assert "H5a. pushers changed: check warns drift, leaves the file" \
  'grep -q "WARN.*authorized_keys drifted" "$TMP/out" && grep -q KEYTWO "$AK"'
MODE=install run07
assert "H5b. install reconciles: the removed key can no longer push" '! grep -q KEYTWO "$AK" && grep -q KEYONE "$AK"'
# `git init --shared` sets denyNonFastForwards on its own — so the kit's own
# reconcile only shows on a repo whose policy was switched off afterwards
git --git-dir="$ROOT/books.git" config receive.denyNonFastForwards false; run07
assert "H6a. policy switched off on an existing repo: check names it" \
  'grep -q "WARN.*books.git: receive.denyNonFastForwards is .false." "$TMP/out"'
MODE=install run07
assert "H6b. install restores it" '[[ "$(cfg books receive.denyNonFastForwards)" == true ]]'

# a relative pushers path resolves next to the conf's REAL file: the conf is a
# link into the machine's role folder, and the pushers file lives beside it
mkdir -p "$TMP/role"; mv "$TMP/hub.conf" "$TMP/role/hub.conf"; ln -s "$TMP/role/hub.conf" "$TMP/hub.conf"
sed -i "s|^git_hub_pushers=.*|git_hub_pushers=pushers.pub|" "$TMP/role/hub.conf"
printf 'ssh-ed25519 AAAAC3NzaKEYROLE role\n' > "$TMP/role/pushers.pub"
MODE=install run07
assert "H7. relative git_hub_pushers resolves beside the conf's real file" 'grep -q KEYROLE "$AK" && ! grep -q KEYONE "$AK"'

# ---------------------------------------------------------------- P. pushes
W="$TMP/wk"; mkdir -p "$W"
git init -q -b main "$W/books"; git -C "$W/books" commit -q --allow-empty -m one
git -C "$W/books" remote add origin "file://$GH/acme/books.git"
git -C "$W/books" push -q "$ROOT/books.git" main >"$TMP/out" 2>&1
S1="$(git -C "$W/books" rev-parse HEAD)"
assert "P1. fast-forward push accepted, logged as one JSON line naming repo, ref, new sha" \
  '[[ "$(git --git-dir="$ROOT/books.git" rev-parse main)" == "$S1" ]] && tail -1 "$ROOT/log/receive.jsonl" | jq -e --arg s "$S1" ".repo==\"books\" and .ref==\"refs/heads/main\" and .new==\$s" >/dev/null'
git -C "$W/books" commit -q --amend --allow-empty -m one-rewritten
git -C "$W/books" push -q --force "$ROOT/books.git" main >"$TMP/out" 2>&1
assert "P2. forced non-fast-forward refused; hub main unchanged" \
  '[[ "$(git --git-dir="$ROOT/books.git" rev-parse main)" == "$S1" ]]'
git -C "$W/books" reset -q --hard "$S1"
git -C "$W/books" push -q "$ROOT/books.git" main:side >/dev/null 2>&1
git -C "$W/books" push -q "$ROOT/books.git" :side >"$TMP/out" 2>&1
assert "P3. branch deletion refused" 'git --git-dir="$ROOT/books.git" rev-parse -q --verify side >/dev/null'

# ---------------------------------------------------------------- W. worker side
WH="$TMP/wkhome"; mkdir -p "$WH/.ssh" "$WH/.aws"; : > "$WH/.aws/credentials"
wkconf() { printf '%s\n' profile=worker headless=yes "$@" > "$TMP/wk.conf"; }
run03() { env PATH="$BIN:/usr/bin:/bin" HOME="$WH" GIT_HOME="$W" HOST_CONF="$TMP/wk.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/worker/03-headless.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
url() { git -C "$W/$1" remote get-url "${2:-origin}"; }
SSHCFG="$WH/.ssh/config"

wkconf; run03
assert "W0. git_hub unset: off by name, origin untouched" \
  'grep -q "OK.*git hub: off" "$TMP/out" && [[ "$(url books)" == "file://$GH/acme/books.git" ]]'
WKON=("git_hub_repos=acme/books acme/wbt")
wkconf git_hub=hub-a.lan "${WKON[@]}"; run03
assert "W1. check: warns, writes no key, no alias, origin untouched" \
  'grep -q "WARN.*git hub" "$TMP/out" && [[ ! -e "$WH/.ssh/git_hub" ]] && ! grep -q "Host git-hub" "$SSHCFG" 2>/dev/null && [[ "$(url books)" == "file://$GH/acme/books.git" ]]'
assert "W1b. a listed repo with no clone is named, not created" 'grep -q "WARN.*wbt.*no clone" "$TMP/out" && [[ ! -e "$W/wbt" ]]'
MODE=install run03
assert "W2a. install: key generated, alias block names the hub" \
  '[[ -f "$WH/.ssh/git_hub" ]] && grep -A8 "^Host git-hub$" "$SSHCFG" | grep -q "HostName hub-a.lan" && grep -A8 "^Host git-hub$" "$SSHCFG" | grep -q "IdentityFile $WH/.ssh/git_hub"'
assert "W2b. origin → git-hub:books.git; the GitHub URL kept as remote github" \
  '[[ "$(url books)" == "git-hub:books.git" && "$(url books github)" == "file://$GH/acme/books.git" ]]'
assert "W2c. probe reaches the hub through the alias" 'grep -q "OK.*books: origin is the hub" "$TMP/out" && grep -q "SSH.*git-hub" "$TMP/ssh.calls"'
before="$(md5sum < "$SSHCFG")"; MODE=install run03
assert "W3. second install: ssh config byte-identical, no git-hub warnings but the missing clone" \
  '[[ "$(md5sum < "$SSHCFG")" == "$before" ]] && [[ "$(grep "WARN.*git.hub\|WARN.*books" "$TMP/out" | grep -vc "wbt has no clone")" == 0 ]]'
wkconf git_hub=hub-b.lan "${WKON[@]}"; run03
assert "W4a. hub moved, check: alias drift warned, config untouched" \
  'grep -q "WARN.*git-hub alias.*hub-b.lan" "$TMP/out" && [[ "$(md5sum < "$SSHCFG")" == "$before" ]]'
MODE=install run03
assert "W4b. install: exactly one alias block, now hub-b; remote URLs unchanged" \
  '[[ "$(grep -c "^Host git-hub$" "$SSHCFG")" == 1 ]] && grep -q "HostName hub-b.lan" "$SSHCFG" && ! grep -q hub-a "$SSHCFG" && [[ "$(url books)" == "git-hub:books.git" ]]'

# ---------------------------------------------------------------- C. the CLI
HUMAN="$TMP/human"; mkdir -p "$HUMAN/site"
git clone -q "file://$GH/acme/books.git" "$HUMAN/site/books" 2>/dev/null || git init -q -b main "$HUMAN/site/books"
mkdir -p "$HUMAN/site/books/scripts"; printf '#!/bin/bash\ntouch "%s/DEPLOYED"\n' "$TMP" > "$HUMAN/site/books/scripts/deploy-site.sh"
cli() { env PATH="$BIN:/usr/bin:/bin" HOME="$HH" GIT_HOME="$HUMAN" HOST_CONF="$TMP/hub.conf" KIT_LOG_DIR="$TMP" \
  bash "$KIT_DIR/components/git-hub/git-hub" "$@" >"$TMP/out" 2>&1; }
cli status
assert "C1. status names books main as not forwarded" 'grep -q "books.*main.*not forwarded" "$TMP/out"'
cli forward books
assert "C2a. forward pushes hub main to the upstream" '[[ "$(git --git-dir="$GH/acme/books.git" rev-parse main)" == "$S1" ]]'
cli status
assert "C2b. then status says forwarded" 'grep -q "books.*main.*forwarded" "$TMP/out" && ! grep -q "books.*main.*not forwarded" "$TMP/out"'
echo dirt > "$HUMAN/site/books/dirt"; git -C "$HUMAN/site/books" add dirt
cli stage books; rc=$?
assert "C3. stage refuses a dirty clone" '(( rc != 0 )) && grep -qi "dirty\|uncommitted" "$TMP/out"'
git -C "$HUMAN/site/books" rm -q --cached dirt; rm "$HUMAN/site/books/dirt"
cli stage books; rc=$?
assert "C4a. stage fast-forwards a clean clone to hub main" '(( rc == 0 )) && [[ "$(git -C "$HUMAN/site/books" rev-parse HEAD)" == "$S1" ]]'
assert "C4b. stage prints the deploy command and does NOT run it" \
  'grep -q "scripts/deploy-site.sh" "$TMP/out" && [[ ! -e "$TMP/DEPLOYED" ]]'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
