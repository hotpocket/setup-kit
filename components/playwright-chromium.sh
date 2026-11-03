#!/bin/bash
# Called by 08 AFTER its existing pin and AppArmor checks/build. No install-deps.
source "$KIT_DIR/components/tool-common.sh"
section "Playwright Chromium ($MODE) — components/playwright-chromium.md"
GSTACK_DIR="${gsdir:-${GIT_HOME:-$(dirname "$KIT_DIR")}/gstack}"
PW_CLI="$GSTACK_DIR/node_modules/playwright/cli.js"
pw_chromium() {
  local pin installed os paths path missing=0 dry runner
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
  # The vendor's dry-run knows the platform-specific revisions and paths.
  # It neither downloads nor garbage-collects, and avoids a copied cache layout.
  dry=$(PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" "$runner" "$PW_CLI" install --dry-run chromium) \
    || { miss "Playwright: browser registry dry-run failed"; return 1; }
  paths=$(sed -n 's/^[[:space:]]*Install location:[[:space:]]*//p' <<< "$dry")
  [[ "$dry" == *chromium* && "$dry" == *headless* && -n "$paths" ]] || { miss "Playwright: registry did not enumerate Chromium and headless shell"; return 1; }
  while IFS= read -r path; do
    [[ "$path" == "$HOME/.cache/ms-playwright/"* ]] || { miss "Playwright: unexpected cache path $path"; return 1; }
    [[ -f "$path/INSTALLATION_COMPLETE" ]] || { warn "Chromium runtime missing: $path"; missing=1; }
  done <<< "$paths"
  if (( missing )); then
    do_or_say env PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" "$runner" "$PW_CLI" install chromium \
      || { miss "Playwright: Chromium install failed"; return 1; }
  else ok "Playwright Chromium and headless shell match gstack $installed"; fi
}
pw_chromium || true
