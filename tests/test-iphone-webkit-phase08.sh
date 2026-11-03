#!/bin/bash
# Phase-level wiring: component_iphone_webkit runs from phase 08 even when
# component_claude_skills=no (iphone needs .configs' link and node, not skills),
# and its --setup is a counted action so bootstrap runs another pass.
source "$(dirname "$0")/tools-fixture.sh"
source "$(dirname "$0")/playwright-fixture.sh"
mkdir -p "$HOME/bin"
cat > "$HOME/bin/iphone" <<'S'
#!/bin/bash
echo "iphone $*" >> "$CALLS"
case "$1" in --check) [[ -f "$HOME/.iphone-ready" ]] ;; --setup) touch "$HOME/.iphone-ready" ;; esac
S
chmod +x "$HOME/bin/iphone"
conf_tools configs=no component_claude_skills=no component_claude_code=no component_iphone_webkit=yes; run08 install
assert 'skills off: phase 08 still runs the iphone check' 'grep -q "iphone --check" "$CALLS"'
# bootstrap.sh's own action predicate (n_act): a pass with zero actions stops converging.
assert 'its --setup is a counted bootstrap action' 'grep -q "iphone --setup" "$CALLS" && grep -E "^  \+ |\] \+ |^  installed: |\] installed: |apt install attempt" "$TMP/out" | grep -q iphone_setup'
finish
