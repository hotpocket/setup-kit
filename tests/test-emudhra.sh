#!/bin/bash
export NODE_FOR_PROBE="$(command -v node)"
source "$(dirname "$0")/tools-fixture.sh"
CHECK="$KIT_DIR/components/emudhra-check"
# Network probes refuse every bad chain and calibrate against a reachable good
# site. Change one answer to make the admission gate fail on purpose.
cat > "$TMP/bin/curl" <<'SH2'
#!/bin/bash
echo "curl $*" >> "$CALLS"
if [[ "$*" == *example.com* ]]; then
 case "$(cat "$STATE/curl-good" 2>/dev/null)" in
  rejected) echo 'curl: (60) SSL certificate problem: unable to get local issuer certificate' >&2; exit 60 ;;
  network) exit 7 ;; timeout) exit 28 ;; dns) exit 6 ;;
 esac
 [[ ! -f "$STATE/offline" ]]; exit $?
fi
[[ -f "$STATE/trust-bad" ]] && exit 0
exit 60
SH2
cat > "$TMP/bin/git" <<'SH2'
#!/bin/bash
echo "git $*" >> "$CALLS"
if [[ "$*" == *github.com/git/git* ]]; then
 case "$(cat "$STATE/git-good" 2>/dev/null)" in
  rejected) echo 'SSL certificate problem: unable to get local issuer certificate' >&2; exit 128 ;;
  network) echo 'Failed to connect to certificate-host: network is unreachable' >&2; exit 128 ;;
 esac
 [[ ! -f "$STATE/offline" ]]; exit $?
fi
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
 process.nextTick(()=>{
  const good=url==='https://example.com', state=process.env.STATE;
  const code=good && fs.existsSync(state+'/node-good') ? fs.readFileSync(state+'/node-good','utf8').trim() : null;
  if (code==='ETIMEDOUT') {q.emit('timeout'); return;}
  if (code) {q.emit('error',{code}); return;}
  if (good || fs.existsSync(state+'/node-trust-bad')) cb({resume(){}});
  else q.emit('error',{code:fs.existsSync(state+'/node-unknown') ? 'ECONNRESET' : fs.existsSync(state+'/node-revoked') ? 'CERT_REVOKED' : 'CERT_SIGNATURE_FAILURE'});
 });
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
if [[ "$*" == *metadata* ]]; then cat "$STATE/python-inventory"; else exec /usr/bin/python3 -B "$FIXTURE/python-probe-driver.py" "$@"; fi
SH2
cat > "$TMP/python-probe-driver.py" <<'PY'
# Execute the checker's real probe with urllib outcomes matching Blender.
import os, pathlib, socket, ssl, sys, types, urllib.error, urllib.request
state = pathlib.Path(os.environ['STATE'])
if (state/'python-output').exists():
 print((state/'python-output').read_text(), end='')
 sys.exit(1 if (state/'python-exit').exists() else 0)
code = sys.argv[sys.argv.index('-c')+1]
sys.argv = ['-c', *sys.argv[sys.argv.index('-c')+2:]]
sys.modules['certifi'] = types.SimpleNamespace(where=lambda: '/fixture/certifi.pem')
ssl.create_default_context = lambda **kw: object()
def open_url(url, timeout, context=None):
 kind = 'certifi' if context is not None else 'python'
 good = url == 'https://example.com'
 mode_file = state/(kind+'-good')
 mode = mode_file.read_text().strip() if good and mode_file.exists() else 'ok' if good else 'rejected'
 if not good and (state/(kind+'-trust-bad')).exists(): mode = 'ok'
 if not good and (state/(kind+'-unknown')).exists(): mode = 'network'
 if mode == 'ok': return object()
 error = {'rejected': ssl.SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1032)'),
          'network': ConnectionResetError('connection reset'), 'timeout': TimeoutError('timed out'),
          'dns': socket.gaierror(-2, 'Name or service not known')}[mode]
 raise urllib.error.URLError(error)
urllib.request.urlopen = open_url
exec(code)
PY
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
   /usr/bin/python3 -B "$TMP/inventory-driver.py" "$CHECK" --check > "$TMP/out" 2>&1
 GATE_RC=$?
}
# Permission/ownership fixtures require no root, chown or real unreadable HOME.
mkdir -p "$ROOT/opt/containerd"
cat > "$TMP/inventory-driver.py" <<'PY'
import errno, os, pathlib, runpy, stat, sys
state = pathlib.Path(os.environ['STATE'])
target = str(pathlib.Path(os.environ['ROOT'])/'opt/containerd')
scandir, stat_fn, access = os.scandir, os.stat, os.access
def mode():
 p = state/'inventory-error'
 return p.read_text().strip() if p.exists() else ''
def fake_scandir(path):
 if str(path) == target and mode():
  if mode() == 'io': raise OSError(errno.EIO, 'Input/output error', target)
  raise PermissionError(errno.EACCES, 'Permission denied', target)
 return scandir(path)
def fake_stat(path, *args, **kw):
 st = stat_fn(path, *args, **kw)
 if str(path) == target and mode():
  if mode() == 'stat-denied': raise PermissionError(errno.EACCES, 'Permission denied', target)
  fields = list(st)
  fields[0] = (stat.S_IFREG if mode() == 'file' else stat.S_IFDIR) | 0o711
  fields[4] = os.getuid() if mode() == 'user' else 0
  return os.stat_result(fields)
 return st
def fake_access(path, flags, *args, **kw):
 if str(path) == target and mode() and flags & os.R_OK:
  return mode() == 'listable'
 return access(path, flags, *args, **kw)
os.scandir, os.stat, os.access = fake_scandir, fake_stat, fake_access
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
PY
conf_tools; run_tools install
assert 'eMudhra default off' '! grep -qE "emudhra|example.com" "$CALLS"'
check_gate
assert 'patched inventory and calibrated TLS pass' '[[ "$GATE_RC" == 0 ]] && grep -q "RESULT: all clear" "$TMP/out" && grep -q "$VENV" "$TMP/out"'
echo root > "$STATE/inventory-error"; check_gate
assert 'root-only unlistable directory is named and skipped' '[[ "$GATE_RC" == 0 ]] && grep -q "SKIPPED.*inventory.*opt/containerd: root-only, not listable by $(id -un)" "$TMP/out"'
for mode in user listable stat-denied file io; do
 echo "$mode" > "$STATE/inventory-error"; check_gate
 assert "inventory $mode error still fails closed" '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED.*inventory.*opt/containerd" "$TMP/out" && ! grep -q "SKIPPED" "$TMP/out"'
done
rm "$STATE/inventory-error"
for kind in python certifi curl git node; do
 echo rejected > "$STATE/$kind-good"
 [[ "$kind" != node ]] || echo UNABLE_TO_GET_ISSUER_CERT_LOCALLY > "$STATE/node-good"
 check_gate
 assert "$kind good-site certificate rejection is NO-STORE" '[[ "$GATE_RC" == 0 ]] && grep -q "NO-STORE.*$kind.*trusts no chain" "$TMP/out" && ! grep -q "UNTESTED" "$TMP/out"'
 if [[ "$kind" != git ]]; then
  marker="$kind-trust-bad"; [[ "$kind" != curl ]] || marker=trust-bad
  touch "$STATE/$marker"; check_gate
  assert "$kind good-site rejection cannot hide trusted bad chains" '[[ "$GATE_RC" != 0 ]] && grep -q "FAIL.*$kind.*trusts 12/12" "$TMP/out" && ! grep -q "NO-STORE.*$kind" "$TMP/out"'
  rm "$STATE/$marker"
 fi
 if [[ "$kind" == python || "$kind" == certifi || "$kind" == node ]]; then
  touch "$STATE/$kind-unknown"; check_gate
  assert "$kind good-site rejection cannot hide unknown bad-chain probes" '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED.*$kind.*12 untested" "$TMP/out"'
  rm "$STATE/$kind-unknown"
 fi
 for error in network timeout dns; do
  [[ "$kind" != git || "$error" == network ]] || continue
  if [[ "$kind" == node ]]; then
   case "$error" in network) echo ECONNRESET ;; timeout) echo ETIMEDOUT ;; dns) echo ENOTFOUND ;; esac > "$STATE/node-good"
  else echo "$error" > "$STATE/$kind-good"; fi
  check_gate
  assert "$kind good-site $error error remains UNTESTED" '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED.*$kind" "$TMP/out" && ! grep -q "NO-STORE.*$kind" "$TMP/out"'
 done
 rm "$STATE/$kind-good"
done
for row in 'python rejected 0 unreadable' 'python rejected nope 0' 'python rejected 0' 'python ok 0 unreadable' 'python rejected 0 0 extra' 'bogus rejected 0 0'; do
 echo "$row" > "$STATE/python-output"; check_gate
 assert "unreadable probe $row fails closed" '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED.*python" "$TMP/out" && ! grep -q "NO-STORE.*python" "$TMP/out"'
done
echo 'python rejected 0 0' > "$STATE/python-output"; touch "$STATE/python-exit"; check_gate
assert 'unsuccessful process cannot claim NO-STORE' '[[ "$GATE_RC" != 0 ]] && grep -q "UNTESTED.*python" "$TMP/out" && ! grep -q "NO-STORE.*python" "$TMP/out"'
rm "$STATE/python-output" "$STATE/python-exit"
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
