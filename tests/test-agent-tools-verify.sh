#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates its expression strings at runtime
source "$(dirname "$0")/tools-fixture.sh"
source "$(dirname "$0")/playwright-fixture.sh"
flags=(component_uv=yes component_blender=yes component_flutter_headless=yes component_playwright_chromium=yes)
conf_tools "${flags[@]}"; runv
for tool in uv blender flutter_headless playwright_chromium; do
  assert "independent verify rejects missing $tool" 'grep -q "FAIL.*agent tool $tool" "$TMP/out"'
done
conf_tools "${flags[@]}"; run_tools install
conf_tools "${flags[@]}" component_claude_skills=yes claude_skills=gstack; run08 install
runv
for tool in uv blender flutter_headless playwright_chromium; do
  assert "independent verify accepts completed pinned $tool" 'grep -q "PASS.*agent tool $tool" "$TMP/out"'
done
printf '#!/bin/sh\necho uv 0.1.0\n' > "$HOME/.local/bin/uv"; runv
assert 'independent uv drift fails' 'grep -q "FAIL.*agent tool uv" "$TMP/out"'
printf '#!/bin/sh\necho Blender 1.0\n' > "$HOME/.local/opt/blender-5.2.2-linux-x64/blender"; runv
assert 'independent Blender drift fails' 'grep -q "FAIL.*agent tool blender" "$TMP/out"'
rm "$HOME/development/flutter/bin/cache/setup-kit-android.complete"; runv
assert 'independent Flutter incomplete precache fails' 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
cp "$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome" "$TMP/chrome-good"
printf 'corrupt executable bytes\n' > "$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome"; runv
assert 'independent browser byte corruption fails before execution' 'grep -q "FAIL.*agent tool playwright_chromium" "$TMP/out"'
cp "$TMP/chrome-good" "$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome"
rm "$HOME/.cache/ms-playwright/ffmpeg-1011/ffmpeg-linux"; runv
assert 'independent browser artifact loss fails' 'grep -q "FAIL.*agent tool playwright_chromium" "$TMP/out"'
printf '{"dependencies":{"playwright":"^1.60.0"}}\n' > "$GS/package.json"
run08 install; rc=$?
assert 'unsupported Playwright pin fails its phase' '[[ $rc != 0 ]] && grep -q "MISS:.*unsupported" "$TMP/out"'
runv
assert 'independent browser support refusal fails' 'grep -q "FAIL.*agent tool playwright_chromium" "$TMP/out"'
conf_tools; runv
assert 'disabled new tool flags add no checks' '! grep -q "agent tool" "$TMP/out"'
finish
