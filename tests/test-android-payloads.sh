#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates runtime expressions
source "$(dirname "$0")/tools-fixture.sh"
conf_tools component_flutter_headless=yes
run_tools install
sdk="$HOME/Android/Sdk"
for item in platform-tools/adb build-tools/36.0.0/aapt2 platforms/android-36/android.jar ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang; do
  cp -p "$sdk/$item" "$TMP/payload-good"
  for defect in missing empty; do
    if [[ "$defect" == missing ]]; then rm -f "$sdk/$item"; else : > "$sdk/$item"; fi
    runv
    assert "$item $defect fails independent verification" 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
    : > "$CALLS"
    bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" check > "$TMP/out" 2>&1
    assert "$item $defect is charged by preflight" 'grep -q "flutter: headless" "$TMP/out"'
    run_tools install
    assert "$item $defect retries its package" 'grep -q "sdkmanager .*--install" "$CALLS" && [[ -s "$sdk/$item" ]]'
    cp -p "$TMP/payload-good" "$sdk/$item"
  done
  if [[ "$item" != *android.jar ]]; then
    chmod -x "$sdk/$item"; runv
    assert "$item without execute permission fails verification" 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
    cp -p "$TMP/payload-good" "$sdk/$item"
  fi
done
cache="$HOME/development/flutter/bin/cache"
for item in android-sdk.stamp artifacts/engine/linux-x64/flutter_tester artifacts/engine/linux-x64/font-subset artifacts/engine/android-arm-release/linux-x64/gen_snapshot; do
  cp -p "$cache/$item" "$TMP/cache-good"; rm "$cache/$item"; runv
  assert "$item loss fails independent verification" 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
  run_tools install
  assert "$item loss refills the verified cache" '[[ -s "$cache/$item" ]] && grep -q "^flutter precache --android" "$CALLS"'
  cp -p "$TMP/cache-good" "$cache/$item"
done
runv
assert 'restored complete Android and engine payload passes' 'grep -q "PASS.*agent tool flutter_headless" "$TMP/out"'
# Interrupt sdkmanager after metadata creation, before its executable payload.
rm -f "$sdk/platform-tools/adb"
printf "Pkg.Revision = 37.0.1\n" > "$sdk/platform-tools/source.properties"
touch "$STATE/pause-sdk"
setsid bash "$KIT_DIR/profiles/workstation/07-components.sh" install > "$TMP/out" 2>&1 & job=$!
for ((i=0;i<400;i++)); do [[ -f "$STATE/sdk-started" ]] && break; sleep .025; done
kill -KILL -- "-$job" 2>/dev/null || true; wait "$job" 2>/dev/null || true
assert 'killed Android package install publishes no new partial metadata' '[[ -f "$STATE/sdk-started" && ! -e "$sdk/platform-tools/adb" && "$(cat "$sdk/platform-tools/source.properties")" == "Pkg.Revision = 37.0.1" ]]'
rm "$STATE/pause-sdk"
run_tools install
assert 'Android package restart recovers staging and repairs the payload' '[[ -x "$sdk/platform-tools/adb" ]] && ! find "$sdk" -maxdepth 1 -name ".android-packages.*" | grep -q .'
finish
