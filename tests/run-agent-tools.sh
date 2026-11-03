#!/bin/bash
# Offline shell calibrations for the opt-in agent tools; no AI or network.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${KIT_AGENT_TESTS_LOCKED:-0}" != 1 ]]; then
  mkdir -p "$HOME/.cache"
  exec flock "$HOME/.cache/beast-heavy.lock" nice -n 10 \
    env KIT_AGENT_TESTS_LOCKED=1 bash "$KIT/tests/run-agent-tools.sh" </dev/null
fi
failed=0
for name in uv blender flutter-headless dev-headless playwright-chromium emudhra \
            emudhra-wiring python-trust-floor tools-defaults tools-disk-space \
            tools-interrupted tmp-on-disk; do
  bash "$KIT/tests/test-$name.sh" || failed=1
done
exit "$failed"
