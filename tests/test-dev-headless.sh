#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools; : > "$CALLS"
packages() { bash -c 'source "$1/lib.sh"; apt_wanted_pkgs' _ "$KIT_DIR" | sed '/^@/d'; }
packages > "$TMP/pkgs"
assert 'headless apt group default off' '! grep -qx ripgrep "$TMP/pkgs"'
conf_tools group_dev_headless=yes; packages > "$TMP/pkgs"
assert 'headless apt group supplies runtime without desktop' 'grep -qx ripgrep "$TMP/pkgs" && grep -qx xvfb "$TMP/pkgs" && grep -qx libasound2t64 "$TMP/pkgs" && grep -qx libegl-mesa0 "$TMP/pkgs" && ! grep -qE "^(ubuntu-desktop|chromium-browser|firefox|android-studio|.*webkit.*)$" "$TMP/pkgs"'
python3 - "$KIT_DIR" "$TMP" <<'PY'
import runpy,sys,pathlib
r=pathlib.Path(sys.argv[1]); g=runpy.run_path(str(r/'capture/90-generate-manifests.py')); p=pathlib.Path(sys.argv[2])
if 'dev-headless' not in g['OPTIONAL']: sys.exit(0)
p.joinpath('generated').write_text('\n'.join(sorted(g['OPTIONAL']['dev-headless'][1]))+'\n')
PY
assert 'generator owns every shipped headless package' '[[ -f "$TMP/generated" ]] && diff -u "$TMP/generated" <(LC_ALL=C sort -u "$TMP/pkgs")'
python3 - "$KIT_DIR" "$TMP" <<'PY2'
import runpy,sys,pathlib,types,contextlib,io
r=pathlib.Path(sys.argv[1]); t=pathlib.Path(sys.argv[2]); g=runpy.run_path(str(r/'capture/90-generate-manifests.py'))
manual=t/'manual'; manual.write_text('fonts-liberation\n')
f=g['main']; state=f.__globals__; state['SNAP']=manual
state['subprocess'].run=lambda *a,**kw: types.SimpleNamespace(stdout='fonts-liberation\t100\tfonts\n')
for name in ('before','after'):
 state['OUT']=t/name
 optional=dict(g['OPTIONAL'])
 if name=='before': optional.pop('dev-headless',None)
 state['OPTIONAL']=optional
 with contextlib.redirect_stdout(io.StringIO()): f()
PY2
assert 'regenerating preserves existing default group requests' 'diff -u "$TMP/before/desktop.list" "$TMP/after/desktop.list"'
cat > "$TMP/bin/apt-cache" <<'SH2'
#!/bin/bash
if [[ "$1" == pkgnames ]]; then
  awk '!/^#/ && NF {print $1}' "$HEADLESS_LIST"
  awk 'BEGIN { for(i=0;i<10010;i++) print "fixture-package-" i }'
fi
SH2
chmod +x "$TMP/bin/apt-cache"
export HEADLESS_LIST="$KIT_DIR/manifests/apt/optional/dev-headless.list"
run02() { : > "$CALLS"; bash "$KIT_DIR/profiles/workstation/02-apt-install.sh" "${1:-check}" > "$TMP/out" 2>&1; }
run02 check
assert 'headless apt check reports missing packages without installing' 'grep -q "WARN.*wanted packages not installed" "$TMP/out" && ! grep -q "apt-get .*install" "$CALLS"'
run02 install
assert 'headless apt install uses guarded noninteractive transaction' 'grep -q "apt-get install -s --no-install-recommends" "$CALLS" && grep -q "sudo DEBIAN_FRONTEND=noninteractive apt-get.*install -y --no-install-recommends" "$CALLS" && [[ -e "$STATE/pkg-ripgrep" && -e "$STATE/pkg-libegl-mesa0" ]]'
run02 install
assert 'headless apt second install performs no transaction' '! grep -q "apt-get .*install" "$CALLS" && grep -q "all .* wanted packages installed" "$TMP/out"'
finish
