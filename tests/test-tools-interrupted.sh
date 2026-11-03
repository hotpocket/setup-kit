#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
# A killed download leaves a partial staging artifact, never a final binary.
# The next run must recover the dead owner's staging and install once.
conf_tools component_uv=yes
sed 's/name=p(sys.argv\[0\]).name/name="curl"/' "$TMP/bin/curl" > "$TMP/bin/curl-ready"
chmod +x "$TMP/bin/curl-ready"
cat > "$TMP/bin/curl" <<'SH2'
#!/bin/bash
if [[ -e "$STATE/pause-download" ]]; then
  while [[ "$1" != -o ]]; do shift; done
  printf partial > "$2"
  touch "$STATE/download-started"
  exec sleep 30
fi
exec "$FIXTURE/bin/curl-ready" "$@"
SH2
chmod +x "$TMP/bin/curl"
touch "$STATE/pause-download"
setsid bash "$KIT_DIR/profiles/workstation/07-components.sh" install > "$TMP/out" 2>&1 & job=$!
for ((i=0;i<200;i++)); do [[ -e "$STATE/download-started" ]] && break; sleep .01; done
kill -KILL -- "-$job" 2>/dev/null || true
wait "$job" 2>/dev/null || true
assert 'kill mid-download never publishes a partial uv' '[[ -e "$STATE/download-started" && ! -e "$HOME/.local/bin/uv" ]]'
rm "$STATE/pause-download"
run_tools install
assert 'restart installs and sweeps dead-owner download staging' '[[ -x "$HOME/.local/bin/uv" ]] && [[ -z "$(find "$HOME/.local/bin" -maxdepth 1 -type d -name ".uv.*" -print)" ]]'
finish
