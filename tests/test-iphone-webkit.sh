#!/bin/bash
# component_iphone_webkit: phase 08 readies .configs' `iphone` check (pinned
# Playwright + isolated WebKit in ~/.cache/iphone-webkit) by running its own
# `--check`, and `--setup` only when that fails, in install mode. Node comes
# from nvm's default when it isn't on PATH (fresh worker phases).
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; CALLS="$TMP/calls"; mkdir -p "$H/bin" "$TMP/bin"
export HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" CALLS PATH="$TMP/bin:/usr/bin:/bin"
unset KIT_RUN_LOG
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out" | tail -6; fi; }
# Fake nvm default node (not on PATH) and a fake iphone that needs it.
mkdir -p "$H/.nvm/versions/node/v26.13.0/bin"
printf '#!/bin/bash\nexit 0\n' > "$H/.nvm/versions/node/v26.13.0/bin/node"; chmod +x "$H/.nvm/versions/node/v26.13.0/bin/node"
printf 'nvm() { [[ "$1 $2" == "which default" ]] && echo "$HOME/.nvm/versions/node/v26.13.0/bin/node"; }\n' > "$H/.nvm/nvm.sh"
iphone() {
  cat > "$H/bin/iphone" <<'S'
#!/bin/bash
command -v node >/dev/null || { echo "env: 'node': No such file or directory" >&2; exit 127; }
echo "iphone $*" >> "$CALLS"
case "$1" in
  --check) [[ -f "$HOME/.ready" ]] && { echo ready; exit 0; }; echo "not ready" >&2; exit 2 ;;
  --setup) [[ -f "$HOME/.setup-fails" ]] && exit 2; touch "$HOME/.ready"; exit 0 ;;
esac
S
  chmod +x "$H/bin/iphone"
}
run() { : > "$CALLS"; bash -c 'source "$1/lib.sh"; init_mode "$2"; source "$1/components/iphone-webkit.sh"' _ "$KIT_DIR" "$1" > "$TMP/out" 2>&1; rc=$?; }
printf 'component_iphone_webkit=yes\n' > "$HOST_CONF"

run install
assert 'no ~/bin/iphone: warns, calls nothing' '[[ $rc == 0 ]] && grep -q "WARN.*iphone" "$TMP/out" && [[ ! -s "$CALLS" ]]'
iphone
run check
assert 'check mode: reports not ready, never runs --setup' 'grep -q "WARN.*iphone.*not ready" "$TMP/out" && ! grep -q -- "--setup" "$CALLS" && [[ ! -f "$H/.ready" ]]'
run install
assert 'install: --check fails, --setup runs once, then --check passes (nvm node found)' '[[ $(grep -c -- "--setup" "$CALLS") == 1 && -f "$H/.ready" ]] && grep -q "\[ OK \].*iphone" "$TMP/out"'
run install
assert 'second install: --check only, no --setup' '! grep -q -- "--setup" "$CALLS" && grep -q -- "--check" "$CALLS"'
rm -f "$H/.ready"; touch "$H/.setup-fails"; run install
assert 'failed --setup is a miss' 'grep -qi "miss.*iphone" "$TMP/out"'
echo "iphone-webkit: $pass passed, $fail failed"
(( fail == 0 ))
