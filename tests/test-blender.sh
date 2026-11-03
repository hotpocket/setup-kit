#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools; run_tools install
assert 'blender default off' '[[ ! -e "$HOME/.local/bin/blender" ]] && ! grep -q "curl .*blender" "$CALLS"'
conf_tools component_blender=yes; run_tools check
assert 'blender check reports drift and changes nothing' 'grep -q "WARN.*blender.*missing" "$TMP/out" && [[ -z "$(mutations)" ]]'
run_tools install
assert 'blender pin, stable directory and bin link, no launcher' '[[ -x "$HOME/.local/opt/blender-5.2.2-linux-x64/blender" && -L "$HOME/.local/opt/blender" && -L "$HOME/.local/bin/blender" && ! -d "$HOME/.local/share/applications" ]] && grep -q "84098912789dc450e95697c4184fb8a90acbe5111c2ba4aede3fecb57806a168" "$STATE/checksum-input"'
run_tools install
assert 'blender second install has no mutation' '[[ -z "$(mutations)" ]]'
rm -rf "$HOME/.local/opt/blender-5.2.2-linux-x64"; touch "$STATE/checksum-fail"; run_tools install
assert 'blender rejects corrupt archive' '[[ ! -e "$HOME/.local/opt/blender-5.2.2-linux-x64" ]] && grep -q "MISS:.*blender" "$TMP/out"'
finish
