#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
export GIT_HOME="$HOME/git"
GS="$GIT_HOME/gstack"
mkdir -p "$GS/node_modules/playwright" "$GS/node_modules/playwright-core"
printf '{"dependencies":{"playwright":"^1.62.1"}}\n' > "$GS/package.json"
printf '{"version":"1.62.1"}\n' > "$GS/node_modules/playwright/package.json"
# CLI fixture answers Playwright's dry-run with paths, then installs those paths.
cat > "$GS/node_modules/playwright/cli.js" <<'JS'
fixture
JS
cat > "$TMP/bin/node" <<'SH2'
#!/bin/bash
echo "node $*" >> "$CALLS"
if [[ "$*" == *--dry-run* ]]; then
  printf 'browser: chromium version 151\n  Install location: %s/.cache/ms-playwright/chromium-1234\nbrowser: chromium-headless-shell version 151\n  Install location: %s/.cache/ms-playwright/chromium_headless_shell-1234\n' "$HOME" "$HOME"
else
  mkdir -p "$HOME/.cache/ms-playwright"/{chromium-1234,chromium_headless_shell-1234}
  touch "$HOME/.cache/ms-playwright"/{chromium-1234,chromium_headless_shell-1234}/INSTALLATION_COMPLETE
fi
SH2
chmod +x "$TMP/bin/node"
# Run through 08, after its existing gstack/AppArmor path. Keep unrelated
# skill work absent (no git checkout) and Claude already installed.
mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\necho claude\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
run08() { : > "$CALLS"; bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" "${1:-check}" > "$TMP/out" 2>&1; }
conf_tools configs=no component_claude_skills=yes claude_skills=gstack; run08 install
assert 'Playwright component default off' '! grep -q "node .*cli.js install" "$CALLS"'
conf_tools configs=no component_claude_skills=yes claude_skills=gstack component_playwright_chromium=yes; run08 check
assert 'Playwright check sees missing browsers and never installs' 'grep -q "WARN.*[Cc]hromium.*missing" "$TMP/out" && ! grep -qE "^node .*install chromium$" "$CALLS" && [[ ! -d "$HOME/.cache/ms-playwright" ]]'
run08 install
assert 'project pinned CLI installs only Chromium and headless shell' 'grep -q "node .*node_modules/playwright/cli.js install chromium$" "$CALLS" && [[ -f "$HOME/.cache/ms-playwright/chromium_headless_shell-1234/INSTALLATION_COMPLETE" ]] && ! grep -qE "node .*webkit|install-deps|--no-sandbox" "$CALLS"'
run08 install
assert 'Playwright second install does not install again' '! grep -qE "^node .*install chromium$" "$CALLS"'
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
assert 'Playwright finds the installed nvm default without bashrc or PATH' 'grep -q "nvm which default" "$CALLS" && grep -q "node .*cli.js install chromium$" "$CALLS" && [[ -f "$HOME/.cache/ms-playwright/chromium-1234/INSTALLATION_COMPLETE" ]]'
printf '{"dependencies":{"playwright":"^1.60.0"}}\n' > "$GS/package.json"; run08 install
assert 'unsafe Ubuntu pin refused before browser CLI runs' 'grep -q "MISS:.*Playwright.*support" "$TMP/out" && ! grep -q "node .*cli.js" "$CALLS"'
finish
