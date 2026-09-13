#!/bin/bash
# aws-cli must be v2, from Amazon's bundle — not Ubuntu's apt `awscli` (v1).
#
# 2026-09-13: verify.sh failed "apt: awscli not-installed" on a box that had a
# working aws — v2 at /usr/local/bin/aws, which dpkg cannot see. The manifest
# said apt, the machine said bundle, and the verifier believed the manifest.
# v2 is the one that matters: ~/.aws/config `sso_session` blocks and
# `aws sso login` against IAM Identity Center (what .configs/bin/sso drives)
# are v2-only. A fresh box provisioned from the apt manifest gets a v1 that
# cannot log in.
#
# Contract:
#   A. verify: aws-cli/2.x on PATH → pass, no aws FAIL
#   B. verify: aws-cli/1.x on PATH → FAIL that names v2
#   C. verify: no aws at all → FAIL
#   D. verify: group_dev_cloud=no → aws not checked at all
#   E. 07-components check mode, v1 on PATH → says v2 is missing (would install)
#   F. 07-components check mode, v2 on PATH → OK line with the version
#   G. the download URL follows the machine arch (x86_64 / aarch64)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }

mkdir -p "$TMP/bin"
# a PATH with no real aws on it: the stub, then the system dirs only
BASE_PATH="$TMP/bin:/usr/bin:/bin"
stub_aws() { printf '#!/bin/sh\necho "aws-cli/%s Python/3.13.11 Linux/6.0 exe/x86_64"\n' "$1" > "$TMP/bin/aws"; chmod +x "$TMP/bin/aws"; }
no_aws()   { rm -f "$TMP/bin/aws"; }
conf()     { printf '%s\n' "$1" > "$TMP/host.conf"; }
verify()   { ( cd "$KIT_DIR" && PATH="$BASE_PATH" KIT_HOST_CONF="$TMP/host.conf" ./verify.sh 2>&1 ); }
phase07()  { ( cd "$KIT_DIR" && PATH="$BASE_PATH" HOST_CONF="$TMP/host.conf" KIT_QUIET=0 bash profiles/workstation/07-components.sh check 2>&1 ); }
aws_lines(){ grep -iE '^FAIL +aws|aws-cli' <<<"$1" | grep -viE 'awscli \(' ; }   # ignore the apt-manifest line if any

echo "verify.sh"
conf 'group_dev_cloud=yes'
stub_aws 2.32.30; v="$(verify)"
assert "A: v2 on PATH — passes, no aws FAIL"          '[[ "$v" != *"FAIL  aws"* ]]'
stub_aws 1.42.0;  v="$(verify)"
assert "B: v1 on PATH — FAIL names v2"                '[[ "$v" == *"FAIL  aws"* && "$(grep "FAIL  aws" <<<"$v")" == *v2* ]]'
no_aws;           v="$(verify)"
assert "C: no aws — FAIL"                             '[[ "$v" == *"FAIL  aws"* ]]'
conf 'group_dev_cloud=no'
assert "D: group_dev_cloud=no — aws not checked"      '[[ "$(verify)" != *"FAIL  aws"* ]]'

echo "07-components.sh (check mode)"
conf 'group_dev_cloud=yes'
stub_aws 1.42.0;  p="$(phase07)"
assert "E: v1 — reports aws-cli v2 missing"           '[[ "$p" == *"aws-cli v2 missing"* ]]'
stub_aws 2.32.30; p="$(phase07)"
assert "F: v2 — OK with version"                      '[[ "$p" == *"[ OK ]"*"aws-cli v2.32.30"* ]]'

echo "download url"
url="$(HOST_CONF=/dev/null bash -c "source '$KIT_DIR/lib.sh'; aws_cli_v2_url x86_64; aws_cli_v2_url aarch64" 2>/dev/null | tr '\n' ' ')"
assert "G: arch-specific Amazon bundle URLs"          '[[ "$url" == "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip "* ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
