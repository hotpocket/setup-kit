#!/bin/bash
# Sourced by phase 07. Never execute the launcher or inspect auth contents.
section "muse ($MODE) — components/muse.md"
MUSE_LAUNCHER="$HOME/.local/bin/muse"

muse_launcher_install() (
  umask 077
  mkdir -p "$(dirname "$MUSE_LAUNCHER")" || exit 1
  stage=$(mktemp "$(dirname "$MUSE_LAUNCHER")/.muse.XXXXXX") || exit 1
  trap 'rm -f "$stage"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 https://api.meta.ai/muse-launcher.sh -o "$stage" \
    && [[ "$(head -n 1 "$stage")" == '#!/usr/bin/env bash' ]] \
    && grep -qxF 'launcher_url="https://api.meta.ai/muse-launcher.sh"' "$stage" \
    && chmod 0755 "$stage" \
    && mv -f "$stage" "$MUSE_LAUNCHER"
)

# Shared JSON write mechanics, with separate policies for Muse and T3.
# Statuses keep file contents and parse errors out of doctor output.
muse_settings() {
  python3 -I - "$1" "$2" "$INSTALL" <<'PY'
import datetime
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

path, kind, install = Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
os.umask(0o077)
try:
    original = path.read_bytes()
    mode = stat.S_IMODE(path.stat().st_mode)
except FileNotFoundError:
    original, mode = None, 0o600
except OSError:
    print("invalid")
    sys.exit(0)
try:
    data = json.loads(original) if original is not None else {"schema_version": 1}
    if not isinstance(data, dict):
        raise ValueError("settings must be an object")
    if kind == "muse":
        needed = data.get("contributor_mode_enabled") is not False
        data["contributor_mode_enabled"] = False
    else:
        # A missing T3 settings file is not an invitation to install T3.
        if original is None:
            print("skipped")
            sys.exit(0)
        providers = data.setdefault("providerInstances", {})
        if not isinstance(providers, dict):
            raise ValueError("providerInstances must be an object")
        needed = "muse" not in providers
        if needed:
            providers["muse"] = {"driver": "muse", "enabled": True}
except (ValueError, UnicodeError):
    print("invalid")
    sys.exit(0)

if not needed:
    print("present")
elif not install:
    print("needed")
else:
    def atomic_write(destination, content):
        fd, stage = tempfile.mkstemp(prefix=".settings.json.tmp-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as out:
                os.fchmod(out.fileno(), mode)
                out.write(content)
                out.flush()
                os.fsync(out.fileno())
            os.replace(stage, destination)
        finally:
            if os.path.exists(stage):
                os.unlink(stage)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == "t3":
            stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S%f")
            atomic_write(path.with_name(path.name + ".bak-" + stamp + "-muse"), original)
        atomic_write(path, (json.dumps(data, indent=2) + "\n").encode())
    except OSError:
        print("failed")
    else:
        print("changed")
PY
}

if [[ -x "$MUSE_LAUNCHER" ]]; then
  ok "muse launcher present (~/.local/bin/muse)"
else
  warn "muse launcher missing or not executable"
  if (( INSTALL )); then
    if muse_launcher_install; then
      log "muse launcher installed"
    else
      miss "muse: launcher download failed or invalid; retry install (components/muse.md)"
    fi
  else
    hint "[would] install muse launcher from https://api.meta.ai/muse-launcher.sh"
  fi
fi

case "$(muse_settings "$HOME/.config/muse/settings.json" muse)" in
  present) ok "muse: contributor mode off" ;;
  changed) log "muse: contributor mode set to off" ;;
  needed) warn "muse: contributor mode must be off"; hint "[would] set contributor_mode_enabled=false in ~/.config/muse/settings.json" ;;
  invalid) miss "muse: unreadable JSON in ~/.config/muse/settings.json; left unchanged; repair it and retry" ;;
  *) miss "muse: settings write failed; check ~/.config/muse permissions and retry" ;;
esac

if [[ ! -e "$HOME/.t3/userdata/settings.json" ]]; then
  ok "muse: T3 not installed; provider skipped"
else
  case "$(muse_settings "$HOME/.t3/userdata/settings.json" t3)" in
    present) ok "muse: T3 provider present" ;;
    changed) log "muse: T3 provider added (settings.json.bak-<date>-muse saved)" ;;
    skipped) ok "muse: T3 not installed; provider skipped" ;;
    needed) warn "muse: T3 provider missing"; hint "[would] back up ~/.t3/userdata/settings.json and add the muse provider" ;;
    invalid) miss "muse: unreadable JSON in ~/.t3/userdata/settings.json; left unchanged; repair it and retry" ;;
    *) miss "muse: T3 settings write failed; check ~/.t3/userdata permissions and retry" ;;
  esac
fi

# -s uses metadata only. No login command, JSON parse or network probe.
if [[ -s "$HOME/.config/muse/auth.json" ]]; then
  ok "muse signed in"
else
  warn "muse not signed in — run: muse login (Meta device flow; Brandon approves the link)"
fi
