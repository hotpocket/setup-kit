#!/bin/bash
# Offline shell calibrations for the opt-in agent tools; no AI or network.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Heavy jobs run on dev only (global rule): send the whole suite there through dev-run,
# which never falls back to this box. The marker stops the copy on dev from sending itself again.
if [[ "${KIT_AGENT_TESTS_ON_DEV:-0}" != 1 ]]; then
  dev_run="${KIT_DEV_RUN:-$(dirname "$KIT")/proxmox_setup_plan/scripts/dev-run}"
  [[ -x "$dev_run" ]] || { echo "run-agent-tools: dev-run not found at $dev_run; not running here" >&2; exit 125; }
  cd "$KIT" && exec "$dev_run" sh -c 'KIT_AGENT_TESTS_ON_DEV=1 bash tests/run-agent-tools.sh'
fi
failed=0
for name in uv blender flutter-headless dev-headless playwright-chromium emudhra \
            emudhra-wiring python-trust-floor tools-defaults tools-disk-space \
            tools-interrupted tmp-on-disk oom-package cloud-skip; do
  bash "$KIT/tests/test-$name.sh" || failed=1
done
exit "$failed"
