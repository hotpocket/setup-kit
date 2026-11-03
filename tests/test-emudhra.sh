#!/bin/bash
export NODE_FOR_PROBE="$(command -v node)"
source "$(dirname "$0")/tools-fixture.sh"
CHECK="$KIT_DIR/components/emudhra-check"
# Network probes refuse every bad chain and calibrate against a reachable good
# site. Change one answer to make the admission gate fail on purpose.
cat > "$TMP/bin/curl" <<'SH2'
#!/bin/bash
echo "curl $*" >> "$CALLS"
[[ "$*" == *example.com* ]] && { [[ ! -f "$STATE/offline" ]]; exit $?; }
[[ -f "$STATE/trust-bad" ]] && exit 0
exit 60
SH2
cat > "$TMP/bin/git" <<'SH2'
#!/bin/bash
echo "git $*" >> "$CALLS"
[[ "$*" == *github.com/git/git* ]] && { [[ ! -f "$STATE/offline" ]]; exit $?; }
echo 'SSL certificate problem: certificate verify failed' >&2
exit 128
SH2
cat > "$TMP/bin/node" <<'SH2'
#!/bin/bash
if [[ "$*" == *--version* ]]; then cat "$STATE/node-version"; else exec "$NODE_FOR_PROBE" -r "$FIXTURE/node-probe-preload.cjs" "$@"; fi
SH2
cat > "$TMP/node-probe-preload.cjs" <<'JS'
const https=require('https'), fs=require('fs'), {EventEmitter}=require('events');
https.get=(url, options, cb)=>{
 const q=new EventEmitter(); q.destroy=()=>{};
 process.nextTick(()=>url==='https://example.com' || fs.existsSync(process.env.STATE+'/node-trust-bad') ? cb({resume(){}}) :
  q.emit('error',{code:fs.existsSync(process.env.STATE+'/node-unknown') ? 'ECONNRESET' : fs.existsSync(process.env.STATE+'/node-revoked') ? 'CERT_REVOKED' : 'CERT_SIGNATURE_FAILURE'}));
 return q;
};
JS
chmod +x "$TMP/bin/"{curl,git,node}
echo v24.22.1 > "$STATE/node-version"
# A deeply nested venv inside .cache used to escape the original scanner.
VENV="$HOME/.cache/deep/a/b/c/d/e/f/venv"
mkdir -p "$VENV/bin"; touch "$VENV/pyvenv.cfg"
cat > "$VENV/bin/python" <<'SH2'
#!/bin/bash
if [[ "$*" == *metadata* ]]; then cat "$STATE/python-inventory"; else echo 'python ok 0'; fi
SH2
chmod +x "$VENV/bin/python"
ln -s python "$VENV/bin/python3"
printf '{"pip":"26.2.2","certifi":"2026.10.19"}\n' > "$STATE/python-inventory"
# Ubuntu usrmerge aliases and distro certifi's system-store override.
mkdir -p "$ROOT/usr/bin"; ln -s usr/bin "$ROOT/bin"
cat > "$ROOT/usr/bin/python3" <<'SH2'
#!/bin/bash
if [[ "$*" == *metadata* ]]; then
 echo system-metadata >> "$CALLS"
 cat "$STATE/system-python-inventory"
else echo 'python ok 0'; fi
SH2
chmod +x "$ROOT/usr/bin/python3"
printf '{"pip":null,"certifi":"2026.1.4","certifi_path":"/etc/ssl/certs/ca-certificates.crt","ssl":true}\n' > "$STATE/system-python-inventory"
# Keep system/interpreter scans confined to fake roots for this standalone test.
check_gate() {
 : > "$CALLS"
 HOME="$HOME" EMUDHRA_SYSTEM_ROOT="$ROOT" EMUDHRA_PATH="$TMP/bin:$ROOT/bin:$ROOT/usr/bin" \
   /usr/bin/python3 "$CHECK" --check > "$TMP/out" 2>&1
 GATE_RC=$?
}
conf_tools; run_tools install
assert 'eMudhra default off' '! grep -qE "emudhra|example.com" "$CALLS"'
check_gate
assert 'patched inventory and calibrated TLS pass' '[[ "$GATE_RC" == 0 ]] && grep -q "RESULT: all clear" "$TMP/out" && grep -q "$VENV" "$TMP/out"'
touch "$STATE/node-revoked"; check_gate
assert 'Node CERT_REVOKED is a rejected chain rather than unknown' 'grep -q "OK.*node.*trusts 0/12 compromised chains; 0 untested" "$TMP/out" && ! grep -q "UNTESTED.*node" "$TMP/out"'
rm "$STATE/node-revoked"
touch "$STATE/node-trust-bad"; check_gate
assert 'Node probe instrument detects trusted compromised chains' 'grep -q "FAIL.*node.*trusts 12/12" "$TMP/out"'
rm "$STATE/node-trust-bad"; touch "$STATE/node-unknown"; check_gate
assert 'Node transport failures remain untested' 'grep -q "UNTESTED.*node.*12 untested" "$TMP/out"'
rm "$STATE/node-unknown"; check_gate
assert 'usrmerge Python aliases inventoried once' '[[ "$(grep -c system-metadata "$CALLS")" == 1 ]]'
assert 'old distro certifi using the patched system store is accepted' '! grep -q "FAIL.*certifi.*2026.1.4" "$TMP/out" && grep -q "OK.*certifi.*system store" "$TMP/out"'
printf '{"pip":null,"certifi":"2026.1.4","certifi_path":"/vendor/cacert.pem","ssl":true}\n' > "$STATE/system-python-inventory"; check_gate
assert 'old bundled certifi still fails its floor' 'grep -q "FAIL.*certifi.*2026.1.4" "$TMP/out"'
printf '{"pip":null,"certifi":"2026.1.4","certifi_path":"/etc/ssl/certs/ca-certificates.crt","ssl":true}\n' > "$STATE/system-python-inventory"
printf '{"pip":"26.2.2","certifi":null,"ssl":false}\n' > "$STATE/system-python-inventory"; check_gate
assert 'SSL-less bundled Python has no TLS consumer rather than an untested probe' 'grep -q "ABSENT.*python-tls" "$TMP/out" && ! grep -q "UNTESTED.*python" "$TMP/out"'
printf '{"pip":null,"certifi":"2026.1.4","certifi_path":"/etc/ssl/certs/ca-certificates.crt","ssl":true}\n' > "$STATE/system-python-inventory"
echo v20.20.0 > "$STATE/node-version"; check_gate
assert 'Node <=20 fails admission' '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*node.*20.20.0" "$TMP/out"'
echo v24.22.0 > "$STATE/node-version"; check_gate
assert 'Node same-major patch floor enforced' '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*node.*24.22.0" "$TMP/out"'
echo v24.22.1 > "$STATE/node-version"
printf '{"pip":"26.2.1","certifi":"2026.10.18"}\n' > "$STATE/python-inventory"; check_gate
assert 'deep cached venv certifi and pip floors enforced separately' '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*certifi.*2026.10.18" "$TMP/out" && grep -q "FAIL.*pip.*26.2.1" "$TMP/out"'
printf '{"pip":null,"certifi":null}\n' > "$STATE/python-inventory"; check_gate
assert 'missing certifi in a venv fails; absent pip is reported absent' 'grep -q "FAIL.*certifi.*absent" "$TMP/out" && grep -q "ABSENT.*pip" "$TMP/out"'
printf '{"pip":"26.2.2","certifi":"2026.10.19"}\n' > "$STATE/python-inventory"
touch "$STATE/trust-bad"; check_gate
assert 'instrument detects a trusted bad chain' '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*curl.*trusts" "$TMP/out"'
rm "$STATE/trust-bad"; touch "$STATE/offline"; check_gate
assert 'offline cannot pass admission' '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED" "$TMP/out"'
assert 'checker never invokes a fix' '! grep -qE "sudo|apt-get|nvm|pip install|clone" "$CALLS"'
rm "$STATE/offline"
echo 20260816ubuntu0.26.04.0 > "$STATE/ca-version"; check_gate
assert 'CA package floor is enforced' '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*ca-certificates.*20260816ubuntu0.26.04.0" "$TMP/out"'
rm "$STATE/ca-version"
for n in 22.23.3 26.12.0; do
 echo "v$n" > "$STATE/node-version"; check_gate
 assert "Node $n below its major floor fails" '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*node" "$TMP/out"'
done
finish
