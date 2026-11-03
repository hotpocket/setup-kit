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
cp "$TMP/payload/uv-x86_64-unknown-linux-gnu/"{uv,uvx} "$HOME/.local/bin/"
bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" check > "$TMP/out" 2>&1
assert 'preflight accepts uv target suffix without charging reinstall' '! grep -q "uv: standalone" "$TMP/out"'
# Install the fixture SDK/browser through the actual component entry points.
source "$(dirname "$0")/playwright-fixture.sh"
conf_tools component_flutter_headless=yes; run_tools install
conf_tools component_claude_skills=yes claude_skills=gstack component_playwright_chromium=yes; run08 install
cat > "$TMP/bin/df" <<'SH2'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 20000000 15000000 5000000 75%% /\n'
SH2
chmod +x "$TMP/bin/df"
preflight() {
  conf_tools configs=no lang_python=no lang_node=no lang_flutter=no component_claude_skills=no space_check=enforce disk_headroom_gb=0 component_flutter_headless=yes component_playwright_chromium=yes
  bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" install > "$TMP/out" 2>&1; rc=$?
}
preflight
assert 'installed SDK and browsers converge with less than reinstall space' '[[ $rc == 0 ]] && ! grep -qE "flutter: headless|Playwright: Chromium" "$TMP/out"'
rm "$HOME/development/flutter/bin/cache/setup-kit-android.complete"; preflight
assert 'interrupted Flutter cache is charged and blocks an undersized reinstall' '[[ $rc == 3 ]] && grep -q "flutter: headless" "$TMP/out"'
rm "$HOME/.cache/ms-playwright/ffmpeg-1011/INSTALLATION_COMPLETE"; preflight
assert 'incomplete browser artifacts are charged as missing' 'grep -q "Playwright: Chromium" "$TMP/out"'
finish
