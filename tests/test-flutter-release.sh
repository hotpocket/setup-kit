#!/bin/bash
# First-invocation code archives include the tool bootstrap and Dart runtime.
# shellcheck disable=SC2034 # assert evaluates its expression strings
source "$(dirname "$0")/tools-fixture.sh"
source "$KIT_DIR/manifests/tool-versions.conf"
conf_tools component_flutter_headless=yes
flutter="$HOME/development/flutter"
mkdir -p "$HOME/development"
# Model the existing same-release Git installation, including obsolete receipts.
git clone fixture "$flutter"
mkdir -p "$flutter/bin/cache/dart-sdk"
printf 'old\n' > "$flutter/bin/cache/dart-sdk/.setup-kit-sha256"
printf 'old\n' > "$flutter/bin/cache/setup-kit-android.complete"
run_tools check
assert 'doctor identifies Git bootstrap as incomplete without changing it' 'grep -q "WARN.*release" "$TMP/out" && [[ ! -s "$flutter/.setup-kit-release.json" ]] && [[ -z "$(mutations)" ]]'
printf 'flutter.tar.xz.part\n' > "$STATE/checksum-fail-for"
run_tools install
assert 'release mismatch preserves existing clone without extracting or launching' 'grep -Fq "$FLUTTER_RELEASE_URL" "$CALLS" && ! grep -q "tar .*flutter.tar.xz" "$CALLS" && ! grep -q "^flutter " "$CALLS" && [[ "$(cat "$flutter/bin/cache/setup-kit-android.complete")" == old ]]'
rm "$STATE/checksum-fail-for"
touch "$STATE/pub-preload-fail"
run_tools install
assert 'offline package preparation failure preserves clone and prevents Flutter launch' 'grep -q "^release-dart pub cache preload" "$CALLS" && ! grep -q "^flutter " "$CALLS" && [[ "$(cat "$flutter/bin/cache/setup-kit-android.complete")" == old ]]'
rm "$STATE/pub-preload-fail"
run_tools install
assert 'first invocation uses verified complete release instead of Git or Dart downloads' 'grep -q "flutter.tar.xz.part" "$STATE/checksum-input" && [[ -s "$flutter/bin/cache/flutter_tools.snapshot" && -s "$flutter/.setup-kit-release.json" ]] && ! grep -qE "^git .*clone|dart-sdk-linux" "$CALLS"'
assert 'same-release clone migration leaves no backup or obsolete Dart receipt' '[[ -z "$(find "$HOME/development" -maxdepth 1 -name "flutter.backup.*" -print)" && ! -e "$flutter/bin/cache/dart-sdk/.setup-kit-sha256" && ! -e "$flutter/bin/cache/dart-sdk/.setup-kit-executables.json" ]]'
assert 'completion identifies release archive instead of retired Dart archive' '[[ "$(cat "$flutter/bin/cache/setup-kit-android.complete")" == "$FLUTTER_REVISION:${FLUTTER_RELEASE_SHA256:-missing}" ]]'
assert 'vendor packages are preloaded and resolved offline before first invocation' 'grep -q "^release-dart pub cache preload" "$CALLS" && grep -q "^release-dart pub get --offline --enforce-lockfile" "$CALLS" && [[ -s "$flutter/.setup-kit-pub-cache/hosted/pub.dev/fixture-1.0.0/fixture.dart" ]]'
assert 'consumed Pub archives cannot be imported later into the user cache' '[[ ! -e "$flutter/.pub-preload-cache" ]]'
assert 'generated package roots survive staged publication without absolute paths' 'python3 - "$flutter" <<'\''PY'\''
import json,pathlib,sys,urllib.parse
root=pathlib.Path(sys.argv[1]); path=root/"packages/flutter_tools/.dart_tool/package_config.json"
data=json.loads(path.read_text())
assert data["packages"]
for item in data["packages"]:
 uri=urllib.parse.urlsplit(item["rootUri"])
 assert not uri.scheme and not uri.path.startswith("/")
 assert (path.parent/urllib.parse.unquote(uri.path)/"pubspec.yaml").is_file()
assert ".flutter." not in path.read_text()
PY'
run_tools install
assert 'release migration converges without downloading or invoking Flutter' '[[ -z "$(mutations)" ]]'
cp "$flutter/bin/cache/flutter_tools.snapshot" "$TMP/snapshot-good"
printf 'corrupt\n' > "$flutter/bin/cache/flutter_tools.snapshot"
runv
assert 'independent verifier rejects corrupt compiled Flutter tool' 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
run_tools install
assert 'managed release repairs corrupt snapshot without retaining backup' 'cmp "$flutter/bin/cache/flutter_tools.snapshot" "$TMP/snapshot-good" && [[ -z "$(find "$HOME/development" -maxdepth 1 -name "flutter.backup.*" -print)" ]] && grep -q "flutter_linux_" "$CALLS"'
runv
assert 'independent verifier accepts repaired release' 'grep -q "PASS.*agent tool flutter_headless" "$TMP/out"'
printf 'corrupt package\n' > "$flutter/.setup-kit-pub-cache/hosted/pub.dev/fixture-1.0.0/fixture.dart"
runv
assert 'independent verifier rejects corruption in vendored Pub sources' 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
run_tools install
assert 'managed package corruption repairs from the release without a backup' 'grep -q "const fixture" "$flutter/.setup-kit-pub-cache/hosted/pub.dev/fixture-1.0.0/fixture.dart" && [[ -z "$(find "$HOME/development" -maxdepth 1 -name "flutter.backup.*" -print)" ]]'
rm "$flutter/.setup-kit-release.json"
runv
assert 'independent verifier requires release receipt even when all caches exist' 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
run_tools install
# A different clone belongs to its owner. Preserve its complete bytes by rename.
printf 'different-revision\n' > "$flutter/HEAD"
rm -f "$flutter/.setup-kit-release.json"
printf 'owner changes\n' > "$flutter/keep-me"
run_tools install
backup=$(find "$HOME/development" -maxdepth 1 -name 'flutter.backup.*' -print -quit)
assert 'different unmanaged tree is preserved and replaced with the pinned release' '[[ -n "$backup" && "$(cat "$backup/keep-me")" == "owner changes" && "$(cat "$flutter/HEAD")" == "$FLUTTER_REVISION" && -s "$flutter/.setup-kit-release.json" ]]'
run_tools install
assert 'backup stays unique across repeat installs' '[[ "$(find "$HOME/development" -maxdepth 1 -name "flutter.backup.*" | wc -l)" == 1 && -z "$(mutations)" ]]'
# Local tracked changes at the pinned revision also make it a different tree.
rm "$flutter/.setup-kit-release.json"
printf 'tracked edit\n' > "$STATE/git-dirty"
run_tools install
assert 'dirty pinned clone is backed up rather than discarded' '[[ "$(find "$HOME/development" -maxdepth 1 -name "flutter.backup.*" | wc -l)" == 2 ]]'
rm "$STATE/git-dirty"
# Source timestamps are a bootstrap input too, despite unchanged file bytes.
touch -d '2030-01-01' "$flutter/packages/flutter_tools/pubspec.yaml"
runv
assert 'independent verifier rejects bootstrap-triggering source timestamps' 'grep -q "FAIL.*agent tool flutter_headless" "$TMP/out"'
run_tools install
assert 'release repairs bootstrap-triggering timestamps before launch' '[[ ! "$flutter/packages/flutter_tools/pubspec.yaml" -nt "$flutter/packages/flutter_tools/pubspec.lock" ]] && grep -q "flutter_linux_" "$CALLS"'
finish
