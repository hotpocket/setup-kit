#!/bin/bash
# Login shells get setup-kit's headless PATH (bun, flutter, java, Android):
# ~/.profile sources ~/.config/setup-kit/headless-env.sh. ~/.ssh/environment
# can't carry PATH on Ubuntu (pam_env resets it), so this is the login route.
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H/.config/setup-kit" "$H/.bun/bin"
export HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="/usr/bin:/bin"
unset KIT_RUN_LOG
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out" | tail -6; fi; }
run() { bash -c 'source "$1/lib.sh"; init_mode "$2"; source "$1/components/tool-common.sh"; source "$1/components/headless-login.sh"' _ "$KIT_DIR" "$1" > "$TMP/out" 2>&1; rc=$?; }
printf 'export PATH="$HOME/.bun/bin:$PATH"\n' > "$H/.config/setup-kit/headless-env.sh"
printf '#!/bin/sh\necho bun-ok\n' > "$H/.bun/bin/bun"; chmod +x "$H/.bun/bin/bun"
# nvm's default node, which nvm itself puts on PATH only when nvm.sh is sourced.
mkdir -p "$H/.nvm/versions/node/v26.13.0/bin"; printf '#!/bin/sh\necho node-ok\n' > "$H/.nvm/versions/node/v26.13.0/bin/node"; chmod +x "$H/.nvm/versions/node/v26.13.0/bin/node"
printf 'export PATH="$HOME/.nvm/versions/node/v26.13.0/bin:$PATH"\n' > "$H/.nvm/nvm.sh"
printf '# ~/.profile\nexport KEEP=1\n' > "$H/.profile"; cp "$H/.profile" "$TMP/profile.orig"
run check
assert 'check reports the missing line and writes nothing' 'grep -q "WARN.*profile" "$TMP/out" && cmp -s "$TMP/profile.orig" "$H/.profile"'
run install
assert 'a login shell finds bun after install' '[[ "$(env -i HOME="$H" PATH=/usr/bin:/bin bash -lc "bun" 2>/dev/null)" == bun-ok ]]'
assert 'a login shell finds nvm'"'"'s default node after install' '[[ "$(env -i HOME="$H" PATH=/usr/bin:/bin bash -lc "node" 2>/dev/null)" == node-ok ]]'
assert 'the existing .profile content is kept' 'grep -qx "export KEEP=1" "$H/.profile"'
cp "$H/.profile" "$TMP/profile.after"; run install
assert 'second install changes nothing' 'cmp -s "$TMP/profile.after" "$H/.profile"'
rm "$H/.profile"; ln -s "$TMP/elsewhere" "$H/.profile"; printf 'x\n' > "$TMP/elsewhere"; run install
assert 'a linked .profile is never written through' '[[ "$(cat "$TMP/elsewhere")" == x ]] && grep -q "WARN.*profile.*linked" "$TMP/out"'
echo "headless-login: $pass passed, $fail failed"
(( fail == 0 ))
