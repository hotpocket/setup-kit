#!/bin/bash
# Called by 08 AFTER its existing pin and AppArmor checks/build. No install-deps.
source "$KIT_DIR/components/tool-common.sh"
section "Playwright Chromium ($MODE) — components/playwright-chromium.md"
GSTACK_DIR="${gsdir:-${GIT_HOME:-$(dirname "$KIT_DIR")}/gstack}"
PW_CLI="$GSTACK_DIR/node_modules/playwright/cli.js"
pw_archive_install() (
  local name="$1" url="$2" sha="$3" dest="$4" exe="$5" stage owner
  tool_x64 Playwright || exit 1
  mkdir -p "${dest%/*}" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "${dest%/*}" "$name" "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "$url" "$sha" "$stage/$name.zip" \
    && mkdir "$stage/payload" && unzip -q "$stage/$name.zip" -d "$stage/payload" \
    && [[ -f "$stage/payload/$exe" ]] \
    && chmod +x "$stage/payload/$exe" \
    && printf '%s\n' "$sha" > "$stage/payload/.setup-kit-sha256" \
    && tool_content_receipt "$stage/payload" "$exe" \
    && touch "$stage/payload/INSTALLATION_COMPLETE" \
    && tool_publish_dir "$stage/payload" "$dest" "$stage"
)
pw_chromium() {
  local pin installed os paths path expected dry runner
  pin=$(python3 -I - "$GSTACK_DIR/package.json" <<'PY'
import json,sys
try: print(json.load(open(sys.argv[1]))['dependencies']['playwright'])
except (OSError,ValueError,KeyError): sys.exit(1)
PY
) || { miss "Playwright: gstack package.json missing; complete phase 08 first"; return 1; }
  installed=$(python3 -I - "$GSTACK_DIR/node_modules/playwright/package.json" <<'PY'
import json,sys
try: print(json.load(open(sys.argv[1]))['version'])
except (OSError,ValueError,KeyError): sys.exit(1)
PY
) || { miss "Playwright: gstack dependencies missing; complete its build first"; return 1; }
  # This apt list is tied to 1.62.1's Ubuntu 26.04 table; a pin change requires
  # reviewing nativeDeps again, never falling back to another OS's browsers.
  if [[ "$pin" != '^1.62.1' && "$pin" != 1.62.1 || "$installed" != 1.62.1 ]]; then
    miss "Playwright: unsupported support/dependency pin ($pin, installed $installed); review nativeDeps before browser install"; return 1
  fi
  os=$( . "${KIT_TOOL_ROOT:-}/etc/os-release" 2>/dev/null; echo "${ID:-}:${VERSION_ID:-}")
  [[ "$os" == ubuntu:26.04 ]] || { miss "Playwright: support is pinned to Ubuntu 26.04 ($os); review OS support first"; return 1; }
  runner=$(command -v node 2>/dev/null || true)
  if [[ -z "$runner" && -s "$HOME/.nvm/nvm.sh" ]]; then
    runner=$(export NVM_DIR="$HOME/.nvm"; source "$HOME/.nvm/nvm.sh" --no-use; nvm which default 2>/dev/null) || runner=''
  fi
  [[ -x "$runner" ]] || { miss "Playwright: Node missing; complete language phase first"; return 1; }
  [[ -f "$PW_CLI" ]] || { miss "Playwright: project CLI missing"; return 1; }
  # Read-only registry calibration; refuse a changed layout before downloading.
  dry=$(PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" "$runner" "$PW_CLI" install --dry-run chromium) \
    || { miss "Playwright: browser registry dry-run failed"; return 1; }
  paths=$(sed -n 's/^[[:space:]]*Install location:[[:space:]]*//p' <<< "$dry" | sort)
  expected=$(printf '%s\n' "$HOME/.cache/ms-playwright/chromium-$PLAYWRIGHT_CHROMIUM_REVISION" \
    "$HOME/.cache/ms-playwright/chromium_headless_shell-$PLAYWRIGHT_CHROMIUM_REVISION" \
    "$HOME/.cache/ms-playwright/ffmpeg-$PLAYWRIGHT_FFMPEG_REVISION" | sort)
  [[ "$paths" == "$expected" ]] || { miss "Playwright: registry layout differs from archive pins; review vendor metadata"; return 1; }
  local name dir sha url exe
  for name in chromium headless ffmpeg; do
    case "$name" in
      chromium) dir="chromium-$PLAYWRIGHT_CHROMIUM_REVISION"; sha="$PLAYWRIGHT_CHROMIUM_SHA256"; url="$PLAYWRIGHT_CHROMIUM_URL"; exe=chrome-linux64/chrome ;;
      headless) dir="chromium_headless_shell-$PLAYWRIGHT_CHROMIUM_REVISION"; sha="$PLAYWRIGHT_HEADLESS_SHA256"; url="$PLAYWRIGHT_HEADLESS_URL"; exe=chrome-headless-shell-linux64/chrome-headless-shell ;;
      ffmpeg) dir="ffmpeg-$PLAYWRIGHT_FFMPEG_REVISION"; sha="$PLAYWRIGHT_FFMPEG_SHA256"; url="$PLAYWRIGHT_FFMPEG_URL"; exe=ffmpeg-linux ;;
    esac
    path="$HOME/.cache/ms-playwright/$dir"
    if [[ -f "$path/INSTALLATION_COMPLETE" && -x "$path/$exe" \
        && "$(cat "$path/.setup-kit-sha256" 2>/dev/null)" == "$sha" ]] && tool_content_valid "$path" "$exe"; then
      ok "Playwright $name matches pinned archive"
    else
      warn "Chromium runtime missing or unverified: $path"
      do_or_say pw_archive_install "$name" "$url" "$sha" "$path" "$exe" \
        || { miss "Playwright: $name archive verification/install failed"; return 1; }
    fi
  done
}
pw_chromium
