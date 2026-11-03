#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
V="$HOME/.local/share/pipx/venvs/tool/bin"
mkdir -p "$V"; touch "${V%/bin}/pyvenv.cfg"
printf '{"pip":"25.1.1","certifi":"2026.1.1"}\n' > "$STATE/python-inventory"
cat > "$V/python" <<'SH2'
#!/bin/bash
if [[ "$*" == *'pip install'* ]]; then
 echo "python $*" >> "$CALLS"
 printf '{"pip":"26.2.2","certifi":"2026.10.19"}\n' > "$STATE/python-inventory"
else cat "$STATE/python-inventory"; fi
SH2
chmod +x "$V/python"
run04() { : > "$CALLS"; bash "$KIT_DIR/profiles/workstation/04-languages.sh" "${1:-check}" > "$TMP/out" 2>&1; }
conf_tools lang_python=no lang_node=no; run04 install
assert 'Python trust-floor default off' '! grep -q "python .*pip install" "$CALLS"'
conf_tools lang_python=no lang_node=no component_emudhra=yes; run04 check
assert 'Python trust-floor doctor detects pipx drift without upgrading' 'grep -q "WARN.*[Pp]ython.*floor" "$TMP/out" && ! grep -q "python .*pip install" "$CALLS"'
run04 install
assert 'Python baseline upgrades pip and certifi inside pipx environment' 'grep -q "python .*pip install.*pip>=26.2.2.*certifi>=2026.10.19" "$CALLS"'
run04 install
assert 'Python trust-floor second install does not upgrade' '! grep -q "python .*pip install" "$CALLS"'
finish
