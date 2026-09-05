#!/bin/bash
# Calibration for lib.sh gh_pick_asset: choose the newest NON-prerelease
# GitHub release that actually ships an asset matching the suffix.
#
# Caught in the wild (2026-09-05): obsidianmd/obsidian-releases' "latest"
# release (v1.13.8) was a mobile-only build — one .apk, no .deb — so
# /releases/latest answered "no amd64.deb asset" and obsidian was skipped,
# although v1.13.7 one release down had the deb. The class: every github-method
# row whose upstream mixes platforms (or pre-releases) in one release stream.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$KIT_DIR/lib.sh"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
FIX='[
 {"tag_name":"v9.9.0","prerelease":true, "draft":false,"assets":[{"browser_download_url":"https://x/v9.9.0/app_9.9.0_amd64.deb"}]},
 {"tag_name":"v1.13.8","prerelease":false,"draft":false,"assets":[{"browser_download_url":"https://x/v1.13.8/app-1.13.8.apk"}]},
 {"tag_name":"v1.13.7","prerelease":false,"draft":false,"assets":[
    {"browser_download_url":"https://x/v1.13.7/app-1.13.7.asar.gz"},
    {"browser_download_url":"https://x/v1.13.7/app_1.13.7_arm64.deb"},
    {"browser_download_url":"https://x/v1.13.7/app_1.13.7_amd64.deb"}]},
 {"tag_name":"v1.13.6","prerelease":false,"draft":false,"assets":[{"browser_download_url":"https://x/v1.13.6/app_1.13.6_amd64.deb"}]}
]'
echo "github asset selection"
got="$(gh_pick_asset 'amd64.deb' <<<"$FIX")"
assert "skips the .apk-only latest release"      '[[ "$got" != *1.13.8* ]]'
assert "skips the pre-release"                    '[[ "$got" != *9.9.0* ]]'
assert "takes the newest release WITH the asset"  '[[ "$got" == "https://x/v1.13.7/app_1.13.7_amd64.deb" ]]'
assert "suffix is a regex anchored at the end"    '[[ "$(gh_pick_asset "without_gui_.*amd64.deb" <<<"$FIX")" == "" ]]'
assert "no match anywhere → empty, exit 1"        '! gh_pick_asset "x86_64.rpm" <<<"$FIX" >/dev/null'
assert "garbage input → empty, no crash"          '[[ -z "$(gh_pick_asset "amd64.deb" <<<"not json" 2>/dev/null)" ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
