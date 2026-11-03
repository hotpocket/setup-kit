#!/bin/bash
# Opted in by component_emudhra; runs AFTER phase 04 creates pyenv/pipx envs.
# Do not bypass PEP 668 or replace a distribution's system pip.
section "Python trust floors ($MODE) — components/emudhra.md"
source "$KIT_DIR/components/tool-common.sh"
while IFS= read -r -d '' python; do
  if "$python" -I -c 'from importlib import metadata
import json
out={}
for n in ("pip","certifi"):
 try: out[n]=metadata.version(n)
 except metadata.PackageNotFoundError: out[n]=None
print(json.dumps(out))' 2>/dev/null | python3 -I -c 'import json,sys
try:
 d=json.load(sys.stdin)
 def v(s): return tuple(map(int,s.split("."))) if s else ()
 sys.exit(0 if v(d["pip"]) >= v(sys.argv[1]) and v(d["certifi"]) >= v(sys.argv[2]) else 1)
except (ValueError,KeyError): sys.exit(1)' "$PYTHON_PIP_VERSION" "$PYTHON_CERTIFI_VERSION"; then
    ok "Python trust floors: $python"
  else
    warn "Python trust floor missing or drifted: $python"
    do_or_say "$python" -m pip install --upgrade "pip>=$PYTHON_PIP_VERSION" "certifi>=$PYTHON_CERTIFI_VERSION" \
      || miss "Python trust floor: $python; bootstrap pip in this owned environment, then rerun"
  fi
done < <(python3 -I - "$HOME" <<'PY'
import os,sys
from pathlib import Path
home=Path(sys.argv[1]); seen=set()
for root in [home/'.pyenv/versions', home/'.local/share/pipx', home/'.local/pipx']:
 if not root.exists(): continue
 for d,dirs,files in os.walk(root):
  if Path(d).name!='bin': continue
  p=next((Path(d)/n for n in ('python','python3') if (Path(d)/n).exists()),None)
  if p and str(p) not in seen:
   seen.add(str(p)); sys.stdout.buffer.write(os.fsencode(p)+b'\0')
PY
)
