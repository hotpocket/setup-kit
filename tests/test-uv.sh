#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools; run_tools install
assert 'uv default off' '! grep -qE "^curl .*uv-|^git .*uv" "$CALLS" && [[ ! -e "$HOME/.local/bin/uv" ]]'
conf_tools component_uv=yes; run_tools check
assert 'uv check reports drift without download' 'grep -q "WARN.*uv.*missing" "$TMP/out" && [[ ! -e "$HOME/.local/bin/uv" ]] && [[ -z "$(mutations)" ]]'
run_tools install
assert 'uv and uvx installed at the pin after checksum' '[[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" ]] && [[ "$("$HOME/.local/bin/uv" --version)" == "uv 0.12.23" ]] && grep -q "9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6" "$STATE/checksum-input"'
run_tools install
assert 'uv second install has no mutation' '[[ -z "$(mutations)" ]]'
rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"; touch "$STATE/checksum-fail"; run_tools install
assert 'uv rejects checksum failure without publishing binaries' '[[ ! -e "$HOME/.local/bin/uv" ]] && grep -q "MISS:.*uv" "$TMP/out"'
finish
