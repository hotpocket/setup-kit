#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools configs=no lang_python=no lang_node=no lang_flutter=no component_claude_skills=no space_check=warn disk_headroom_gb=0 \
 component_uv=yes component_blender=yes component_flutter_headless=yes component_playwright_chromium=yes component_emudhra=yes
: > "$CALLS"
bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" check > "$TMP/out" 2>&1
assert 'preflight accounts for all opted-in tools and headless JDK' 'grep -q "uv: standalone" "$TMP/out" && grep -q "blender: batch" "$TMP/out" && grep -q "flutter: headless" "$TMP/out" && grep -q "Playwright: Chromium" "$TMP/out" && grep -q "JDK 21: headless" "$TMP/out" && grep -q "eMudhra: admission" "$TMP/out"'
assert 'preflight never downloads tools' '! grep -qE "^curl |^sudo " "$CALLS"'
mkdir -p "$HOME/.local/bin" "$HOME/.local/opt/blender-5.2.2-linux-x64"
printf '#!/bin/sh\necho uv 0.9.18\n' > "$HOME/.local/bin/uv"
printf '#!/bin/sh\necho uvx 0.9.18\n' > "$HOME/.local/bin/uvx"
printf '#!/bin/sh\necho Blender 5.2.1 LTS\n' > "$HOME/.local/opt/blender-5.2.2-linux-x64/blender"
chmod +x "$HOME/.local/bin/"{uv,uvx} "$HOME/.local/opt/blender-5.2.2-linux-x64/blender"
bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" check > "$TMP/out" 2>&1
assert 'preflight charges drifted existing uv and Blender pins' 'grep -q "uv: standalone" "$TMP/out" && grep -q "blender: batch" "$TMP/out"'
finish
