#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates runtime expressions
source "$(dirname "$0")/tools-fixture.sh"
conf_tools component_flutter_headless=yes
# Only committed artifact rows can authorize an executable download.
export FLUTTER_CACHE_UNLISTED='zip|unreviewed.zip|unreviewed|payload|0000000000000000000000000000000000000000000000000000000000000000'
run_tools install
unset FLUTTER_CACHE_UNLISTED
cache="$HOME/development/flutter/bin/cache"
assert 'uncommitted environment artifact is never downloaded' '! grep -q unreviewed.zip "$CALLS"'
assert 'verified engine payload exists before Flutter precache' '[[ -x "$cache/artifacts/engine/linux-x64/flutter_tester" && -x "$cache/artifacts/engine/linux-x64/font-subset" && -x "$cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot" && -s "$cache/setup-kit-cache.json" ]]'
for artifact in ANDROID_ARM_PROFILE_SNAPSHOT ANDROID_ARM_RELEASE_SNAPSHOT ANDROID_ARM64_PROFILE_SNAPSHOT ANDROID_ARM64_RELEASE_SNAPSHOT ANDROID_X64_PROFILE_SNAPSHOT ANDROID_X64_RELEASE_SNAPSHOT ANDROID_X86 ANDROID_X64 ANDROID_ARM ANDROID_ARM_PROFILE ANDROID_ARM_RELEASE ANDROID_ARM64 ANDROID_ARM64_PROFILE ANDROID_ARM64_RELEASE ANDROID_X64_PROFILE ANDROID_X64_RELEASE HOST PATCHED PATCHED_PRODUCT SKY_ENGINE FLUTTER_GPU FONT_SUBSET FONTS GRADLE ENGINE_INFO; do
  rm -rf "$cache/artifacts" "$cache/pkg" "$cache/setup-kit-cache.json"
  printf '%s.%s.part\n' "$artifact" "$([[ "$artifact" == GRADLE ]] && echo tgz || { [[ "$artifact" == ENGINE_INFO ]] && echo file || echo zip; })" > "$STATE/checksum-fail-for"
  : > "$STATE/checksum-input"
  run_tools install
  assert "$artifact mismatch blocks extraction, precache and completion" 'grep -q "$artifact\." "$STATE/checksum-input" && ! grep -q "unzip .*precache\." "$CALLS" && ! grep -q "^flutter " "$CALLS" && [[ ! -e "$cache/setup-kit-android.complete" && ! -e "$cache/artifacts/engine/linux-x64/flutter_tester" ]]'
done
rm "$STATE/checksum-fail-for"
run_tools install
assert 'retry after archive failure publishes the complete verified cache' '[[ -s "$cache/setup-kit-cache.json" && -s "$cache/setup-kit-android.complete" ]] && grep -q "^flutter precache --android" "$CALLS"'
run_tools install
assert 'verified artifacts converge without more downloads' '! grep -qE "^curl |^flutter " "$CALLS"'
# Exercise the real instrument against non-Dart bytes, keeping unrelated pins stubbed.
cp "$TMP/bin/sha256sum" "$TMP/bin/sha256sum-stub"
cat > "$TMP/bin/sha256sum" <<'SH'
#!/bin/bash
line=$(cat)
if [[ "$line" == *HOST.zip.part* ]]; then printf '%s\n' "$line" | /usr/bin/sha256sum "$@"
else printf '%s\n' "$line" | "$FIXTURE/bin/sha256sum-stub" "$@"; fi
SH
chmod +x "$TMP/bin/sha256sum"
rm -rf "$cache/artifacts" "$cache/setup-kit-cache.json"
run_tools install
assert 'real SHA256 rejects a mismatched non-Dart engine archive before extraction' 'grep -q "did NOT match" "$TMP/out" && ! grep -q "unzip .*precache\." "$CALLS" && ! grep -q "^flutter " "$CALLS" && [[ ! -e "$cache/setup-kit-android.complete" ]]'
finish
