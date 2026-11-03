#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates its expression strings at runtime
source "$(dirname "$0")/tools-fixture.sh"
source "$(dirname "$0")/playwright-fixture.sh"
sed 's/name=p(sys.argv\[0\]).name/name="curl"/' "$TMP/bin/curl" > "$TMP/bin/curl-ready"
chmod +x "$TMP/bin/curl-ready"
cat > "$TMP/bin/curl" <<'SH2'
#!/bin/bash
if [[ -f "$STATE/pause-download" && "$*" == *"$PAUSE_URL"* ]]; then
  while [[ "$1" != -o ]]; do shift; done
  printf partial > "$2"
  printf '%s\n' "${2%/*}" > "$STATE/stage-path"
  touch "$STATE/download-started"
  exec sleep 120
fi
exec "$FIXTURE/bin/curl-ready" "$@"
SH2
chmod +x "$TMP/bin/curl"
for runtime in flutter chromium engine; do
  label=$runtime
  rm -f "$STATE/download-started" "$STATE/stage-path"
  if [[ "$runtime" == flutter ]]; then
    conf_tools component_flutter_headless=yes
    phase=07-components; export PAUSE_URL=flutter_linux_3.47.2-stable.tar.xz
    target="$HOME/development/flutter/bin/cache/dart-sdk/bin/dart"
  elif [[ "$runtime" == engine ]]; then
    conf_tools component_flutter_headless=yes
    phase=07-components; export PAUSE_URL=/linux-x64/artifacts.zip
    target="$HOME/development/flutter/bin/cache/artifacts/engine/linux-x64/flutter_tester"
    label=precache
    rm -rf "$HOME/development/flutter/bin/cache/artifacts" "$HOME/development/flutter/bin/cache/setup-kit-cache.json"
  else
    conf_tools component_claude_skills=yes claude_skills=gstack component_playwright_chromium=yes
    phase=08-claude-skills; export PAUSE_URL=chrome-linux64.zip
    target="$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome"
  fi
  touch "$STATE/pause-download"
  setsid bash "$KIT_DIR/profiles/workstation/$phase.sh" install > "$TMP/out" 2>&1 & job=$!
  for ((i=0;i<400;i++)); do [[ -e "$STATE/download-started" ]] && break; sleep .025; done
  stage=$(cat "$STATE/stage-path" 2>/dev/null || true)
  owner=${stage##*/.$label.}; owner=${owner%%.*}
  assert "$runtime active staging records a live owner" '[[ -d "$stage" && "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null'
  kill -KILL -- "-$job" 2>/dev/null || true; wait "$job" 2>/dev/null || true
  assert "$runtime killed download publishes no executable" '[[ -e "$STATE/download-started" && ! -e "$target" ]]'
  rm "$STATE/pause-download"
  bash "$KIT_DIR/profiles/workstation/$phase.sh" install > "$TMP/out" 2>&1
  assert "$runtime rerun recovers dead staging and completes" '[[ -x "$target" && ! -e "$stage" ]]'
done
finish
