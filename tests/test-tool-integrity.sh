#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
source "$(dirname "$0")/playwright-fixture.sh"
source "$KIT_DIR/manifests/tool-versions.conf"
conf_tools component_flutter_headless=yes
printf 'dart.zip.part\n' > "$STATE/checksum-fail-for"
run_tools install
assert 'Dart checksum failure prevents extraction and Flutter execution' 'grep -q "dart-sdk-linux-x64.zip" "$CALLS" && ! grep -q "unzip .*dart.zip" "$CALLS" && ! grep -q "^flutter " "$CALLS" && [[ ! -e "$HOME/development/flutter/bin/cache/dart-sdk/bin/dart" ]]'
rm "$STATE/checksum-fail-for"
run_tools install
assert 'Dart is verified and published before Flutter bootstrap' '[[ -x "$HOME/development/flutter/bin/cache/dart-sdk/bin/dart" && "$(cat "$HOME/development/flutter/bin/cache/engine-dart-sdk.stamp")" == "$FLUTTER_ENGINE_REVISION" && "$(cat "$HOME/development/flutter/bin/cache/dart-sdk/.setup-kit-sha256")" == "$FLUTTER_DART_SHA256" ]] && grep -q "dart.zip.part" "$STATE/checksum-input"'
for name in chromium headless ffmpeg; do
  rm -rf "$HOME/.cache/ms-playwright"
  printf '%s.zip.part\n' "$name" > "$STATE/checksum-fail-for"
  conf_tools configs=no component_claude_skills=yes claude_skills=gstack component_playwright_chromium=yes
  run08 install
  assert "$name checksum failure prevents that archive extraction and vendor installer" 'grep -q "$name.zip.part" "$STATE/checksum-input" && ! grep -q "unzip .*/$name.zip " "$CALLS" && ! grep -qE "^node .*install chromium$" "$CALLS" && grep -q "MISS:.*Playwright" "$TMP/out"'
done
rm "$STATE/checksum-fail-for"
run08 install
assert 'all browser archives have integrity receipts before completion' '[[ "$(cat "$HOME/.cache/ms-playwright/chromium-1234/.setup-kit-sha256")" == "$PLAYWRIGHT_CHROMIUM_SHA256" && "$(cat "$HOME/.cache/ms-playwright/chromium_headless_shell-1234/.setup-kit-sha256")" == "$PLAYWRIGHT_HEADLESS_SHA256" && "$(cat "$HOME/.cache/ms-playwright/ffmpeg-1011/.setup-kit-sha256")" == "$PLAYWRIGHT_FFMPEG_SHA256" ]] && ! grep -qE "^node .*install chromium$" "$CALLS"'
# The real checksum program must also reject these intentionally fake bytes.
cp /usr/bin/sha256sum "$TMP/bin/sha256sum"
rm -rf "$HOME/development/flutter/bin/cache/dart-sdk"
conf_tools component_flutter_headless=yes; run_tools install
assert 'real SHA256 mismatch blocks the fake Dart archive before extraction' 'grep -q "did NOT match" "$TMP/out" && ! grep -q "unzip .*dart.zip" "$CALLS" && ! grep -q "^flutter " "$CALLS"'
finish
