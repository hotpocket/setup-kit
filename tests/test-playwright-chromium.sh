#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
source "$(dirname "$0")/playwright-fixture.sh"
conf_tools configs=no component_claude_skills=yes claude_skills=gstack; run08 install
assert 'Playwright component default off' '! grep -q "node .*cli.js install" "$CALLS"'
conf_tools configs=no component_claude_skills=yes claude_skills=gstack component_playwright_chromium=yes; run08 check
assert 'Playwright check sees missing browsers and never installs' 'grep -q "WARN.*[Cc]hromium.*missing" "$TMP/out" && ! grep -qE "^node .*install chromium$" "$CALLS" && [[ ! -d "$HOME/.cache/ms-playwright" ]]'
run08 install
assert 'pinned archives install only Chromium, headless shell and ffmpeg' 'grep -q "curl .*chrome-linux64.zip" "$CALLS" && grep -q "curl .*ffmpeg-linux.zip" "$CALLS" && [[ -f "$HOME/.cache/ms-playwright/chromium_headless_shell-1234/INSTALLATION_COMPLETE" ]] && ! grep -qE "node .*webkit|install-deps|--no-sandbox" "$CALLS"'
run08 install
assert 'Playwright second install does not install again' '! grep -qE "^curl |^node .*install chromium$" "$CALLS"'
# Fresh worker phases do not inherit nvm's PATH from phase 04.
mkdir -p "$HOME/.nvm/versions/node/v24.22.1/bin"
cp "$TMP/bin/node" "$HOME/.nvm/versions/node/v24.22.1/bin/node"
cat > "$HOME/.nvm/nvm.sh" <<'SH2'
nvm() { echo "nvm $*" >> "$CALLS"; [[ "$1 $2" == 'which default' ]] && echo "$HOME/.nvm/versions/node/v24.22.1/bin/node"; }
SH2
cat > "$TMP/no-path-node" <<'SH2'
command() { [[ "$*" != '-v node' ]] || return 1; builtin command "$@"; }
SH2
rm -rf "$HOME/.cache/ms-playwright"
BASH_ENV="$TMP/no-path-node" run08 install
assert 'Playwright finds the installed nvm default without bashrc or PATH' 'grep -q "nvm which default" "$CALLS" && grep -q "curl .*chrome-linux64.zip" "$CALLS" && [[ -f "$HOME/.cache/ms-playwright/chromium-1234/INSTALLATION_COMPLETE" ]]'
printf '{"dependencies":{"playwright":"^1.60.0"}}\n' > "$GS/package.json"; run08 install
assert 'unsafe Ubuntu pin refused before browser CLI runs' 'grep -q "MISS:.*Playwright.*support" "$TMP/out" && ! grep -q "node .*cli.js" "$CALLS"'
finish
