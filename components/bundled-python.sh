#!/bin/bash
# Vendor Python may have no SSL. Bootstrap from a verified wheel rather than
# relying on that interpreter's installed pip or network support.
bundle_python_missing() { # interpreter certifi-required
  "$1" -I -B -c 'from importlib import metadata
import json
out={}
for name in ("pip","certifi"):
 try: out[name]=metadata.version(name)
 except metadata.PackageNotFoundError: out[name]=None
print(json.dumps(out))' 2>/dev/null | python3 -I -c 'import json,re,sys
try: data=json.load(sys.stdin)
except (ValueError,TypeError): data={}
def v(s): return tuple(map(int,re.findall(r"\d+",s or "")))
for name,minimum in [("pip",sys.argv[1])]+([("certifi",sys.argv[2])] if sys.argv[3]=="yes" else []):
 if v(data.get(name)) < v(minimum): print(name)
' "$PYTHON_PIP_VERSION" "$PYTHON_CERTIFI_VERSION" "$2"
}
bundle_python_upgrade() ( # interpreter missing-package...
  local python="$1" parent="$HOME/.cache/setup-kit" owner=$BASHPID stage name wheel
  shift
  mkdir -p "$parent" || exit 1
  stage=$(tool_stage "$parent" python-floor "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  wheel="$stage/pip-$PYTHON_PIP_VERSION-py3-none-any.whl"
  tool_fetch "$PYTHON_PIP_WHEEL_URL" "$PYTHON_PIP_SHA256" "$wheel" || exit 1
  local -a packages=()
  for name; do
    case "$name" in
      pip) packages+=("$wheel") ;;
      certifi)
        tool_fetch "$PYTHON_CERTIFI_WHEEL_URL" "$PYTHON_CERTIFI_SHA256" \
          "$stage/certifi-$PYTHON_CERTIFI_VERSION-py3-none-any.whl" || exit 1
        packages+=("$stage/certifi-$PYTHON_CERTIFI_VERSION-py3-none-any.whl") ;;
      *) exit 1 ;;
    esac
  done
  "$python" -I -B -c 'import runpy,sys
sys.path.insert(0,sys.argv.pop(1))
runpy.run_module("pip",run_name="__main__")' "$wheel" \
    install --no-index --no-deps --disable-pip-version-check --upgrade "${packages[@]}"
)
bundle_python_floor() { # label interpreter certifi-required
  local label="$1" python="$2" certifi="$3" missing
  local -a packages=()
  if [[ ! -x "$python" ]]; then
    warn "$label missing: $python"
    (( ! INSTALL )) || miss "$label: bundled interpreter unavailable"
    return
  fi
  missing=$(bundle_python_missing "$python" "$certifi")
  if [[ -z "$missing" ]]; then ok "$label trust floors"; return; fi
  warn "$label trust floors missing or drifted: $python"
  mapfile -t packages <<< "$missing"
  if do_or_say bundle_python_upgrade "$python" "${packages[@]}"; then
    if (( INSTALL )) && [[ -n "$(bundle_python_missing "$python" "$certifi")" ]]; then
      miss "$label: package floors still unmet after upgrade"
    fi
  else miss "$label: pinned wheel upgrade failed; rerun after restoring download access"; fi
}
