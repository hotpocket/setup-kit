#!/bin/bash
# Calibration for the worker tailnet (2026-09-16).
#
# A worker is reached over the tailnet, never a public tunnel: t3code binds the
# LAN/tailnet address and devices pair through Tailscale Serve HTTPS
# (components/t3code.md). So `tailscale` has to BE on the box — and the worker
# profile skips the snap phase (headless=yes), which is where a workstation
# gets it. Hence apt: the repo in 01-apt-repos.sh, gated on group_worker, and
# the package in manifests/apt/optional/worker.list.
#
# Installing it is not joining it. `tailscale up` authenticates this machine to
# a human's tailnet; no cron may do that. Same rule as every credential on a
# worker: verify, name the command, never seed (03-headless §7).
#
# Contract:
#   A. repo, group_worker=yes  → 01-apt-repos proposes pkgs.tailscale.com for
#      THIS release's codename, signed-by the VENDOR's keyring path. Not the
#      script's $KEYDIR default: apt compares keyring PATHS, not keys, so a
#      kit-written entry at a different path than a vendor-shipped one is the
#      Signed-By clash that killed all of apt for vscode and steam.
#   B. repo, group_worker=no   → not proposed (a workstation uses the snap)
#   C. manifest: tailscale is in the worker apt group, and the generator that
#      writes that file agrees — a regen must not drop it
#   D. doctor, no binary       → warns by name, names the group that installs it
#   E. doctor, NeedsLogin      → warns, names `tailscale up`, proposes nothing
#   F. doctor, Running, operator unset → warns, names `tailscale set --operator`
#      (the failure this catches: `tailscale serve` is state-changing, so the
#      t3code user service is refused unless $USER is the operator — pairing
#      dies with an access-denied that names nothing)
#   G. doctor, Running, operator set   → OK, reports the tailnet name
#   H. doctor, prefs unreadable → says UNKNOWN, does not claim "unset"
#      (an instrument that cannot see must refuse, not guess)
#
# NOTE: the `tailscale` stub here reproduces the documented shapes of
# `status --json` (BackendState) and `debug prefs` (OperatorUser). It pins the
# doctor's PARSING, not the real binary's output — no tailscale on the box that
# wrote this. First real run is the confirmation.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }

H="$TMP/home"; BIN="$TMP/bin"
mkdir -p "$BIN"
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"

# ---- A/B: the apt repo, gated on the worker group --------------------------
# check mode only: repo() warns + hints the sources line and touches nothing.
repos() {  # $1 = group_worker value
  printf 'profile=worker\nheadless=yes\ngroup_worker=%s\n' "$1" > "$TMP/host.conf"
  env HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/workstation/01-apt-repos.sh" check > "$TMP/out" 2>&1
}

repos yes
assert "A. group_worker=yes: tailscale repo proposed for $CODENAME, vendor keyring path" \
  'grep -q "pkgs.tailscale.com/stable/ubuntu '"$CODENAME"' main" "$TMP/out" &&
   grep -q "signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg" "$TMP/out"'

repos no
assert "B. group_worker=no: not proposed (workstations take the snap)" \
  '! grep -q "tailscale" "$TMP/out"'

# ---- C: the manifest, and the generator that regenerates it ----------------
echo "manifest"
assert "C1. tailscale is in the worker apt group" \
  'grep -qE "^tailscale[[:space:]]" "$KIT_DIR/manifests/apt/optional/worker.list"'
assert "C2. the generator lists it too — a regen must not drop it" \
  'python3 - "$KIT_DIR" <<'"'"'PY'"'"'
import re, sys, pathlib
src = (pathlib.Path(sys.argv[1]) / "capture/90-generate-manifests.py").read_text()
body = src.split('"'"'"worker": ('"'"', 1)[1].split("]),", 1)[0]
sys.exit(0 if '"'"'"tailscale"'"'"' in body else 1)
PY'

# ---- D-H: the doctor (03-headless §7) --------------------------------------
echo "doctor (03-headless)"
# stubs for everything §1-§6 touches, so only the tailnet section can differ
for s in systemctl loginctl sudo lspci nvidia-smi apt-mark; do
  printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; is-enabled|is-active) exit 0;; esac\nexit 0\n' > "$BIN/$s"
done
printf '#!/bin/bash\necho "arn:aws:iam::1:user/pub"\nexit 0\n' > "$BIN/aws"
chmod +x "$BIN/"*

# tailscale stub: $TS_STATE picks the backend state, $TS_OPERATOR the prefs.
# TS_OPERATOR=__ERR__ makes `debug prefs` fail, like a daemon that refuses.
cat > "$TMP/tailscale.stub" <<'S'
#!/bin/bash
case "$*" in
  "status --json")
    printf '{"BackendState":"%s","Self":{"DNSName":"ai-3090.tail1234.ts.net."}}\n' "${TS_STATE:-Running}" ;;
  "debug prefs")
    [[ "${TS_OPERATOR:-}" == "__ERR__" ]] && { echo "access denied" >&2; exit 1; }
    printf '{\n\t"ControlURL": "https://controlplane.tailscale.com",\n\t"OperatorUser": "%s",\n\t"WantRunning": true\n}\n' "${TS_OPERATOR:-}" ;;
  *) exit 0 ;;
esac
S
chmod +x "$TMP/tailscale.stub"
have_ts() { cp "$TMP/tailscale.stub" "$BIN/tailscale"; }

doctor() {  # env: TS_STATE, TS_OPERATOR
  rm -rf "$H"; mkdir -p "$H/.ssh" "$H/.aws"; : > "$H/.aws/credentials"
  printf 'profile=worker\nheadless=yes\ngroup_worker=yes\ngit_push=deny\n' > "$TMP/host.conf"
  env PATH="$BIN:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/host.conf" \
      KIT_LOG_DIR="$TMP" KIT_QUIET=0 TS_STATE="${TS_STATE:-}" TS_OPERATOR="${TS_OPERATOR:-}" \
    bash "$KIT_DIR/profiles/worker/03-headless.sh" "${MODE:-check}" 2>&1 \
    | grep -i 'tailscale\|tailnet' > "$TMP/out"
}

rm -f "$BIN/tailscale"; doctor
assert "D. no binary: warns by name and names the group that installs it" \
  'grep -q "WARN.*tailscale missing" "$TMP/out" && grep -q "group_worker" "$TMP/out"'

have_ts
TS_STATE=NeedsLogin doctor
assert "E. NeedsLogin: warns, names \`tailscale up\`, proposes nothing" \
  'grep -q "WARN.*not joined" "$TMP/out" && grep -q "tailscale up" "$TMP/out" && ! grep -q "\[would\]" "$TMP/out"'

TS_STATE=Running TS_OPERATOR= doctor
assert "F. Running, operator unset: warns and names the operator command" \
  'grep -q "WARN.*operator" "$TMP/out" && grep -q "tailscale set --operator=$USER" "$TMP/out"'

TS_STATE=Running TS_OPERATOR="$USER" doctor
assert "G. Running, operator set: OK, reports the tailnet name" \
  'grep -q "OK.*tailnet.*ai-3090.tail1234.ts.net" "$TMP/out" && ! grep -q "WARN" "$TMP/out"'

TS_STATE=Running TS_OPERATOR=__ERR__ doctor
assert "H. prefs unreadable: says unknown, does NOT claim the operator is unset" \
  'grep -qi "operator unknown" "$TMP/out" && ! grep -q "operator not set" "$TMP/out"'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
