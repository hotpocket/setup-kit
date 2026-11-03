#!/bin/bash
# Sourced only by opted-in tool components. Final files appear by rename.
source "$KIT_DIR/manifests/tool-versions.conf"
# shellcheck disable=SC2034 # consumed by flutter-headless.sh
TOOL_ROOT="${KIT_TOOL_ROOT:-}"
tool_version_is() { # executable tool-name version; vendor target metadata may follow
  local name version _metadata
  [[ -x "$1" ]] || return 1
  read -r name version _metadata < <("$1" --version 2>/dev/null)
  [[ "$name" == "$2" && "$version" == "$3" ]]
}
tool_property() { # Java .properties assignment; spaces around '=' are optional
  awk -v key="$2" 'index($0,"=") {
    k=substr($0,1,index($0,"=")-1); gsub(/^[ \t]+|[ \t\r]+$/,"",k)
    if(k==key) {v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t\r]+$/,"",v); print v; exit}
  }' "$1" 2>/dev/null
}
tool_x64() { [[ "$(uname -m)" == x86_64 ]] || { miss "$1: only Linux x86_64 is pinned"; return 1; }; }
# Staging names carry their owner's PID. Recover only dead owners; a live
# concurrent provisioner keeps its scratch. Final artifacts are never swept.
tool_stage() { # parent label owner-pid
  local parent="$1" label="$2" owner="$3" old pid tail
  for old in "$parent/.$label."*; do
    [[ -d "$old" && ! -L "$old" ]] || continue
    tail=${old##*/.$label.}; pid=${tail%%.*}
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null && [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" != Z* ]]; then
      continue
    fi
    rm -rf -- "$old"
  done
  mktemp -d "$parent/.$label.$owner.XXXXXX"
}
tool_fetch() { # URL SHA256 destination — caller owns scratch directory
  local url="$1" sha="$2" dest="$3"
  curl -fsSL --retry 3 "$url" -o "$dest.part" \
    && printf '%s  %s\n' "$sha" "$dest.part" | sha256sum -c - \
    && mv "$dest.part" "$dest"
}
tool_link() { # target link — caller runs inside do_or_say
  local target="$1" link="$2" tmp
  [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0
  [[ ! -e "$link" || -L "$link" ]] || { echo "refusing unmanaged $link" >&2; return 1; }
  mkdir -p "$(dirname "$link")" || return 1
  tmp=$(mktemp -d "$(dirname "$link")/.link.XXXXXX") || return 1
  ln -s "$target" "$tmp/link" && mv -Tf "$tmp/link" "$link"
  local rc=$?; rmdir "$tmp"; return "$rc"
}
tool_write() { # content path; user-owned, preserve external symlinks
  local want="$1" path="$2" tmp perm=644
  [[ -f "$path" && "$(cat "$path")" == "$want" ]] && return 0
  [[ ! -L "$path" ]] || { miss "headless environment: refusing symlink $path; update its owner"; return 1; }
  mkdir -p "$(dirname "$path")" || return 1
  [[ ! -f "$path" ]] || perm=$(stat -c %a "$path")
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  printf '%s\n' "$want" > "$tmp" && chmod "$perm" "$tmp" && mv -f "$tmp" "$path"
}

# Both directories are on the same filesystem. An interrupted publication
# leaves a missing destination, which the next run refetches, never a partial one.
tool_publish_dir() { # staged-directory destination scratch-directory
  local src="$1" dest="$2" scratch="$3"
  [[ ! -L "$dest" ]] || return 1
  if [[ -e "$dest" ]]; then mv -T "$dest" "$scratch/previous" || return 1; fi
  mv -T "$src" "$dest"
}

# Package receipts can survive deletion of executable/data payloads.
tool_android_payload() { # SDK directory, sdkmanager package token
  local sdk="$1" package="$2" entry
  case "$package" in
    platform-tools) entry=platform-tools/adb ;;
    platforms\;*) entry="${package//;/\/}/android.jar" ;;
    build-tools\;*) entry="${package//;/\/}/aapt2" ;;
    ndk\;*) entry="${package//;/\/}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ;;
    *) return 1 ;;
  esac
  [[ -s "$sdk/$entry" ]] && { [[ "$package" == platforms\;* ]] || [[ -x "$sdk/$entry" ]]; }
}

# Read-only installed-state probes for space accounting. The independent
# verifier deliberately implements its own checks.
tool_flutter_cache_ready() {
  python3 -I "$KIT_DIR/components/flutter-cache.py" check "$KIT_DIR" "$HOME/development/flutter/bin/cache"
}
tool_flutter_release_ready() {
  local flutter="$HOME/development/flutter"
  [[ -x "$flutter/bin/flutter" && "$(git -C "$flutter" rev-parse HEAD 2>/dev/null)" == "$FLUTTER_REVISION" ]] \
    && python3 -I "$KIT_DIR/components/flutter-release.py" check "$KIT_DIR" "$flutter"
}
tool_flutter_installed() {
  tool_flutter_release_ready || return 1
  tool_flutter_cache_ready || return 1
  local flutter="$HOME/development/flutter" sdk="$HOME/Android/Sdk" package props expected value
  [[ -x "$flutter/bin/flutter" && -x "$flutter/bin/cache/dart-sdk/bin/dart" \
    && "$(git -C "$flutter" rev-parse HEAD 2>/dev/null)" == "$FLUTTER_REVISION" \
    && "$(cat "$flutter/bin/cache/engine-dart-sdk.stamp" 2>/dev/null)" == "$FLUTTER_ENGINE_REVISION" \
    && "$(cat "$flutter/bin/cache/setup-kit-android.complete" 2>/dev/null)" == "$FLUTTER_REVISION:$FLUTTER_RELEASE_SHA256" \
    && -x "$sdk/cmdline-tools/latest/bin/sdkmanager" && -s "$sdk/licenses/android-sdk-license" \
    && "$(readlink "$sdk/cmdline-tools/latest" 2>/dev/null)" == "$ANDROID_TOOLS_VERSION" \
    && "$(tool_property "$sdk/cmdline-tools/$ANDROID_TOOLS_VERSION/source.properties" Pkg.Revision)" == "$ANDROID_TOOLS_VERSION" ]] || return 1
  python3 -I - "$flutter/bin/cache/flutter.version.json" "$FLUTTER_VERSION" "$FLUTTER_DART_VERSION" <<'PY' || return 1
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    sys.exit(0 if (d.get('frameworkVersion'),d.get('dartSdkVersion'))==tuple(sys.argv[2:]) else 1)
except (OSError,ValueError): sys.exit(1)
PY
  for package in platform-tools "platforms;$ANDROID_PLATFORM" "build-tools;$ANDROID_BUILD_TOOLS" "ndk;$ANDROID_NDK"; do
    tool_android_payload "$sdk" "$package" || return 1
    props="$sdk/${package//;/\/}/source.properties"; expected="${package#*;}"
    case "$package" in
      platform-tools) value=$(tool_property "$props" Pkg.Revision); [[ "$value" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1 ;;
      platforms\;*) [[ "$(tool_property "$props" AndroidVersion.ApiLevel)" == "${ANDROID_PLATFORM#android-}" ]] || return 1 ;;
      *) [[ "$(tool_property "$props" Pkg.Revision)" == "$expected" ]] || return 1 ;;
    esac
  done
}
tool_playwright_installed() {
  local gs="${GIT_HOME:-$(dirname "$KIT_DIR")}/gstack" dir sha exe row
  python3 -I - "$gs/package.json" "$gs/node_modules/playwright/package.json" "$PLAYWRIGHT_VERSION" <<'PY' || return 1
import json,sys
try:
    want=json.load(open(sys.argv[1]))['dependencies']['playwright']
    got=json.load(open(sys.argv[2]))['version']
    sys.exit(0 if want in (sys.argv[3],'^'+sys.argv[3]) and got==sys.argv[3] else 1)
except (OSError,ValueError,KeyError): sys.exit(1)
PY
  for row in "chromium-$PLAYWRIGHT_CHROMIUM_REVISION:$PLAYWRIGHT_CHROMIUM_SHA256:chrome-linux64/chrome" \
    "chromium_headless_shell-$PLAYWRIGHT_CHROMIUM_REVISION:$PLAYWRIGHT_HEADLESS_SHA256:chrome-headless-shell-linux64/chrome-headless-shell" \
    "ffmpeg-$PLAYWRIGHT_FFMPEG_REVISION:$PLAYWRIGHT_FFMPEG_SHA256:ffmpeg-linux"; do
    IFS=: read -r dir sha exe <<< "$row"
    [[ -f "$HOME/.cache/ms-playwright/$dir/INSTALLATION_COMPLETE" \
      && -x "$HOME/.cache/ms-playwright/$dir/$exe" \
      && "$(cat "$HOME/.cache/ms-playwright/$dir/.setup-kit-sha256" 2>/dev/null)" == "$sha" ]] || return 1
    tool_content_valid "$HOME/.cache/ms-playwright/$dir" "$exe" || return 1
  done
}

# Record executable bytes only after the containing archive passed its pin.
# This receipt detects later disk corruption; the archive pin is the trust root.
tool_content_receipt() {
  python3 -I - "$1" "$2" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); entry=sys.argv[2]
(root/'.setup-kit-executables.json').write_text(json.dumps({entry:hashlib.sha256((root/entry).read_bytes()).hexdigest()})+'\n')
PY
}
tool_content_valid() {
  python3 -I - "$1" "$2" <<'PY'
import hashlib,json,pathlib,sys
try:
 root=pathlib.Path(sys.argv[1]); entry=sys.argv[2]
 receipt=json.loads((root/'.setup-kit-executables.json').read_text())
 sys.exit(0 if receipt=={entry:hashlib.sha256((root/entry).read_bytes()).hexdigest()} else 1)
except (OSError,ValueError): sys.exit(1)
PY
}
