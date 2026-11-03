#!/bin/bash
# Opted in by component_emudhra; runs AFTER phase 04 creates pyenv/pipx envs.
# Do not bypass PEP 668 or replace a distribution's system pip.
section "Python trust floors ($MODE) — components/emudhra.md"
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
 sys.exit(0 if v(d["pip"]) >= (26,2,2) and v(d["certifi"]) >= (2026,10,19) else 1)
except (ValueError,KeyError): sys.exit(1)'; then
    ok "Python trust floors: $python"
  else
    warn "Python trust floor missing or drifted: $python"
    do_or_say "$python" -m pip install --upgrade 'pip>=26.2.2' 'certifi>=2026.10.19' \
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
