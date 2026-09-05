#!/bin/bash
# lib.sh android_sdk_resolve: flutter.list rows say 'latest' / 'current-stable';
# sdkmanager --list has the real tokens. Caught 2026-09-05: 'platforms;latest'
# resolved to 'platforms;android-37' — a PREFIX of android-37.0/37.1/37.2 that
# is not itself a package — so sdkmanager failed it on every pass. Whole
# tokens only, numeric versions only (no -beta/-ext/rc), highest by version.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$KIT_DIR/lib.sh"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
LIST='Installed packages:
  Path                 | Version | Description
  build-tools;36.0.0   | 36.0.0  | Android SDK Build-Tools 36
Available Packages:
  build-tools;37.0.0   | 37.0.0  | Android SDK Build-Tools 37
  build-tools;37.1.0-rc1 | 37.1.0 rc1 | Android SDK Build-Tools 37.1-rc1
  platforms;android-36 | 2       | Android SDK Platform 36
  platforms;android-36-ext18 | 1 | Android SDK Platform 36-ext18
  platforms;android-37.0 | 1     | Android SDK Platform 37.0
  platforms;android-37.2 | 1     | Android SDK Platform 37.2
  platforms;android-37.2-beta3 | 1 | Android SDK Platform 37.2-beta3
  platforms;android-9  | 1       | Android SDK Platform 9
  system-images;android-36;google_apis;x86_64 | 9 | Google APIs Intel x86_64 Atom System Image
  system-images;android-37.1;google_apis;x86_64 | 1 | Google APIs Intel x86_64 Atom System Image
  system-images;android-37.2-beta3;google_apis;x86_64 | 1 | beta
  system-images;android-37.1;google_apis_playstore;x86_64 | 1 | play'
r() { android_sdk_resolve "$1" <<<"$LIST"; }
echo "android sdk token resolution"
assert "platforms;latest → highest whole stable token"   '[[ "$(r "platforms;latest")" == "platforms;android-37.2" ]]'
assert "build-tools;latest skips rc"                      '[[ "$(r "build-tools;latest")" == "build-tools;37.0.0" ]]'
assert "system image current-stable keeps the variant"   '[[ "$(r "system-images;current-stable;google_apis;x86_64")" == "system-images;android-37.1;google_apis;x86_64" ]]'
assert "literal rows pass through"                       '[[ "$(r "platform-tools")" == "platform-tools" ]]'
assert "version sort, not string sort (9 < 36)"          '[[ "$(r "platforms;latest" | grep -c android-9)" == 0 ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
