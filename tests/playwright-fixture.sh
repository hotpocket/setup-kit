#!/bin/bash
# This helper is sourced after tools-fixture.sh. It is harmless when enumerated.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || exit 0
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
  printf 'browser: chromium version 151\n  Install location: %s/.cache/ms-playwright/chromium-1234\nbrowser: chromium-headless-shell version 151\n  Install location: %s/.cache/ms-playwright/chromium_headless_shell-1234\nbrowser: ffmpeg\n  Install location: %s/.cache/ms-playwright/ffmpeg-1011\n' "$HOME" "$HOME" "$HOME"
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
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/bun"; chmod +x "$TMP/bin/bun"
