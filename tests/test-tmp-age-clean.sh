#!/bin/bash
# The suite may put /tmp on tmpfs. Use the checkout's backing filesystem,
# overridable for an explicit ext4 scratch location. All cleanup is private.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_AGE_SCRATCH="${TMP_AGE_SCRATCH:-$KIT_DIR/logs}"
mkdir -p "$TMP_AGE_SCRATCH"
python3 "$KIT_DIR/tests/tmp-age-calibration.py" "$TMP_AGE_SCRATCH"
