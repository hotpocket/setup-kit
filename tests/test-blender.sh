#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools; run_tools install
assert 'blender default off' '[[ ! -e "$HOME/.local/bin/blender" ]] && ! grep -q "curl .*blender" "$CALLS"'
conf_tools component_blender=yes; run_tools check
assert 'blender check reports drift and changes nothing' 'grep -q "WARN.*blender.*missing" "$TMP/out" && [[ -z "$(mutations)" ]]'
run_tools install
assert 'blender pin, stable directory and bin link, no launcher' '[[ -x "$HOME/.local/opt/blender-5.2.2-linux-x64/blender" && -L "$HOME/.local/opt/blender" && -L "$HOME/.local/bin/blender" && ! -d "$HOME/.local/share/applications" ]] && grep -q "84098912789dc450e95697c4184fb8a90acbe5111c2ba4aede3fecb57806a168" "$STATE/checksum-input"'
PY="$HOME/.local/opt/blender/5.2/python/bin/python3.13"
assert 'Blender bundled pip and certifi reach pinned floors in first install' 'grep -q "26.2.2" "${PY%/*}/packages.json" && grep -q "2026.10.19" "${PY%/*}/packages.json"'
run_tools install
assert 'blender second install has no mutation' '[[ -z "$(mutations)" ]] && ! grep -q "bundle-python .*install" "$CALLS"'
printf '{"pip":"26.0.1","certifi":"2025.4.26","ssl":true}\n' > "${PY%/*}/packages.json"
run_tools check
assert 'Blender doctor reports bundled Python drift without mutation' 'grep -q "WARN.*Blender.*Python" "$TMP/out" && ! grep -q "bundle-python .*install" "$CALLS"'
run_tools install
assert 'Blender repairs bundle without reextracting archive' 'grep -q "bundle-python .*install" "$CALLS" && ! grep -q "curl .*blender-" "$CALLS"'
printf '{"pip":"26.0.1","certifi":"2025.4.26","ssl":true}\n' > "${PY%/*}/packages.json"
touch "$STATE/checksum-fail"; run_tools install
assert 'bundle wheel checksum failure prevents Python mutation' '! grep -q "bundle-python .*install" "$CALLS" && grep -q "MISS:.*Blender" "$TMP/out"'
rm "$STATE/checksum-fail"; run_tools install
assert 'bundle repair recovers after a failed wheel download' 'grep -q "26.2.2" "${PY%/*}/packages.json" && grep -q "2026.10.19" "${PY%/*}/packages.json"'
rm -rf "$HOME/.local/opt/blender-5.2.2-linux-x64"; touch "$STATE/checksum-fail"; run_tools install
assert 'blender rejects corrupt archive' '[[ ! -e "$HOME/.local/opt/blender-5.2.2-linux-x64" ]] && grep -q "MISS:.*blender" "$TMP/out"'
finish
