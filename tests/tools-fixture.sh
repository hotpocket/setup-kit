#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/memory-fixture.sh"
export KIT_TOOL_ROOT="$ROOT" GIT_HOME="$HOME/repos" FIXTURE="$TMP"
mkdir -p "$GIT_HOME" "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin/java"
chmod +x "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin/java"
for c in curl git sdkmanager apt-get dpkg-query sha256sum; do
  cat > "$TMP/bin/$c" <<'PY'
#!/usr/bin/python3
import os,sys,pathlib,shutil,subprocess,json
p=pathlib.Path; args=sys.argv[1:]; name=p(sys.argv[0]).name
with open(os.environ['CALLS'],'a') as f: f.write(name+' '+' '.join(args)+'\n')
s=p(os.environ['STATE']); home=p(os.environ['HOME'])
if name=='curl':
 if (s/'curl-fail').exists(): sys.exit(22)
 url=next(a for a in args if a.startswith('https:')); dest=args[args.index('-o')+1]
 src='pip-26.2.2-py3-none-any.whl' if '/pip-' in url else 'certifi-2026.10.19-py3-none-any.whl' if '/certifi-' in url else 'uv.tar.gz' if 'uv-' in url else 'blender.tar.xz' if 'blender-' in url else 'dart.zip' if 'dart-sdk-linux' in url else 'chromium.zip' if 'chrome-linux64.zip' in url else 'headless.zip' if 'chrome-headless-shell-linux64.zip' in url else 'ffmpeg.zip' if 'ffmpeg-linux.zip' in url else 'android.zip'
 cache=json.loads((p(os.environ['FIXTURE'])/'cache-fixtures.json').read_text())
 src=cache.get(url.removeprefix('https://storage.googleapis.com/'),src)
 shutil.copyfile(p(os.environ['FIXTURE'])/src,dest)
elif name=='sha256sum':
 line=sys.stdin.read()
 with (s/'checksum-input').open('a') as f: f.write(line)
 sys.exit(1 if (s/'checksum-fail').exists() or ((s/'checksum-fail-for').exists() and (s/'checksum-fail-for').read_text().strip() in line) else 0)
elif name=='git':
 if 'clone' in args:
  d=p(args[-1]); (d/'.git').mkdir(parents=True); (d/'bin/cache').mkdir(parents=True)
  (d/'bin/flutter').write_text('#!/bin/sh\necho "flutter $*" >> "$CALLS"\nmkdir -p "$HOME/development/flutter/bin/cache"\nprintf \'{"frameworkVersion":"3.47.2","dartSdkVersion":"3.13.2"}\\n\' > "$HOME/development/flutter/bin/cache/flutter.version.json"\n')
  (d/'bin/flutter').write_text((d/'bin/flutter').read_text()+   'if [ -f "$STATE/precache-fail" ]; then exit 42; fi\nif [ -f "$STATE/precache-pause" ]; then touch "$STATE/precache-started"; sleep 120; fi\nprintf "a804b261645ef8c13eb3d5c44a5c2fb0340c5539\\n" > "$HOME/development/flutter/bin/cache/android-sdk.stamp"\n')
  (d/'bin/flutter').chmod(0o755); (d/'HEAD').write_text('d3b14c876900e553bc736ca19295fc09e3853e8e')
 elif 'rev-parse' in args:
  d=p(args[args.index('-C')+1]); print((d/'HEAD').read_text() if (d/'HEAD').exists() else 'abc123')
 elif 'status' in args: pass
elif name=='sdkmanager':
 sdk=p(next((a.split('=',1)[1] for a in args if a.startswith('--sdk_root=')),str(home/'Android/Sdk')))
 if '--licenses' in args:
  (sdk/'licenses').mkdir(parents=True,exist_ok=True)
  (sdk/'licenses/android-sdk-license').write_text('accepted\n')
 else:
  for a in args:
   if a.startswith('-'): continue
   d=sdk/a.replace(';','/'); d.mkdir(parents=True,exist_ok=True)
   (d/'source.properties').write_text(('AndroidVersion.ApiLevel=36' if a=='platforms;android-36' else 'Pkg.Revision = '+a.split(';')[-1] if a.startswith('ndk;') else 'Pkg.Revision='+('37.0.1' if a=='platform-tools' else a.split(';')[-1]))+'\n')
   if a=='platform-tools' and (s/'pause-sdk').exists():
    import time
    (s/'sdk-started').touch(); time.sleep(120)
   payload=('adb' if a=='platform-tools' else 'aapt2' if a.startswith('build-tools;') else 'android.jar' if a.startswith('platforms;') else 'toolchains/llvm/prebuilt/linux-x86_64/bin/clang')
   file=d/payload; file.parent.mkdir(parents=True,exist_ok=True); file.write_text('fixture Android payload\n'); file.chmod(0o644 if payload=='android.jar' else 0o755)
   if a.startswith('ndk;'):
    d=d/'toolchains/llvm/prebuilt/linux-x86_64/python3/bin'; d.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(p(os.environ['FIXTURE'])/'bin/bundle-python',d/'python3.11'); (d/'python3.11').chmod(0o755)
    if not (d/'python3').exists(): (d/'python3').symlink_to('python3.11')
elif name=='dpkg-query':
 pkg=args[-1]; print(((s/'ca-version').read_text().strip() if (s/'ca-version').exists() else '20260816ubuntu0.26.04.1') if pkg=='ca-certificates' else 'install ok installed' if (s/('pkg-'+pkg)).exists() else '')
 sys.exit(0 if pkg=='ca-certificates' or (s/('pkg-'+pkg)).exists() else 1)
elif name=='apt-get':
 if '-s' in args:
  if (s/'apt-sim-fail').exists(): sys.exit(100)
  if (s/'apt-removal-for').exists() and (s/'apt-removal-for').read_text().strip() in args: print('Remv protected-package [1.0]')
  sys.exit(0)
 if 'install' in args and '-s' not in args:
  for a in args[args.index('install')+1:]:
   if not a.startswith('-'): (s/('pkg-'+a)).touch()
PY
  chmod +x "$TMP/bin/$c"
done
# Safety boundary: only apt and fake-root writes can pass sudo.
cat > "$TMP/bin/sudo" <<'SH2'
#!/bin/bash
echo "sudo $*" >> "$CALLS"
case "$1" in apt-get) exec "$FIXTURE/bin/apt-get" "${@:2}" ;; debconf-set-selections) cat >/dev/null; exit 0 ;; /usr/sbin/sshd) echo "sshd $*" >> "$CALLS"; [[ ! -f "$STATE/sshd-fail" ]] || exit 1; [[ "$*" != *-T* ]] || echo 'permituserenvironment PATH,ANDROID_HOME,ANDROID_SDK_ROOT,JAVA_HOME'; exit 0 ;; DEBIAN_FRONTEND=*) shift; exec "$@" ;; systemctl) exec "$@" ;;
mkdir|chmod|mv|install|cp|tee|mktemp|rm)
  for a in "${@:2}"; do
    case "$a" in /*) [[ "$a" == "$ROOT"/* || "$a" == "$HOME"/* || "$a" == "$FIXTURE"/* ]] || exit 99 ;; esac
  done
  exec "$@" ;; *) exit 99 ;;
esac
SH2
chmod +x "$TMP/bin/sudo"
# Vendor metadata observed on t910; NDK Python has no _ssl module.
cat > "$TMP/bin/bundle-python" <<'PY'
#!/usr/bin/python3
import json,os,pathlib,sys
p=pathlib.Path; args=sys.argv[1:]; here=p(sys.argv[0]); ndk='ndk' in str(here)
state=here.parent/'packages.json'
data=json.loads(state.read_text()) if state.exists() else {'pip':'23.1.2' if ndk else '26.0.1','certifi':None if ndk else '2025.4.26','ssl':not ndk}
if 'install' in args:
 with open(os.environ['CALLS'],'a') as f: f.write('bundle-python '+str(here)+' '+' '.join(args).replace('\n','\\n')+'\n')
 if '--no-index' not in args or '--no-deps' not in args: sys.exit(99)
 if (p(os.environ['STATE'])/'bundle-pip-fail').exists(): sys.exit(1)
 for name,ver in [('pip','26.2.2'),('certifi','2026.10.19')]:
  if any(p(a).name.startswith(name+'-'+ver) for a in args[args.index('install')+1:]): data[name]=ver
 state.write_text(json.dumps(data))
else: print(json.dumps(data))
PY
chmod +x "$TMP/bin/bundle-python"
printf 'fake wheel\n' > "$TMP/pip-26.2.2-py3-none-any.whl"
printf 'fake wheel\n' > "$TMP/certifi-2026.10.19-py3-none-any.whl"
# Download fixtures contain executable behaviour, not mocks of component functions.
mkdir -p "$TMP/payload/uv-x86_64-unknown-linux-gnu" "$TMP/payload/blender-5.2.2-linux-x64" "$TMP/payload/cmdline-tools/bin"
printf '#!/bin/sh\necho "uv 0.12.23 (x86_64-unknown-linux-gnu)"\n' > "$TMP/payload/uv-x86_64-unknown-linux-gnu/uv"
printf '#!/bin/sh\necho "uvx 0.12.23 (x86_64-unknown-linux-gnu)"\n' > "$TMP/payload/uv-x86_64-unknown-linux-gnu/uvx"
printf '#!/bin/sh\necho "Blender 5.2.2 LTS"\n' > "$TMP/payload/blender-5.2.2-linux-x64/blender"
printf '#!/bin/sh\nexec "$FIXTURE/bin/sdkmanager" "$@"\n' > "$TMP/payload/cmdline-tools/bin/sdkmanager"
printf 'Pkg.Revision=22.0\n' > "$TMP/payload/cmdline-tools/source.properties"
chmod +x "$TMP/payload"/*/{uv,uvx,blender} "$TMP/payload/cmdline-tools/bin/sdkmanager" 2>/dev/null || true
/usr/bin/tar -czf "$TMP/uv.tar.gz" -C "$TMP/payload" uv-x86_64-unknown-linux-gnu
mkdir -p "$TMP/payload/blender-5.2.2-linux-x64/5.2/python/bin"
cp "$TMP/bin/bundle-python" "$TMP/payload/blender-5.2.2-linux-x64/5.2/python/bin/python3.13"
/usr/bin/tar -cJf "$TMP/blender.tar.xz" -C "$TMP/payload" blender-5.2.2-linux-x64
/usr/bin/python3 - "$TMP" <<'PY'
import sys,pathlib,zipfile
p=pathlib.Path(sys.argv[1]); z=zipfile.ZipFile(p/'android.zip','w')
for f in (p/'payload/cmdline-tools').rglob('*'):
 if f.is_file(): z.write(f,f.relative_to(p/'payload'))
z.close()
PY
printf 'ID=ubuntu\nVERSION_ID=26.04\n' > "$ROOT/etc/os-release"
conf_tools() { conf component_docker_rootless=skip "$@"; }
run_tools() { run07 "${1:-check}"; }
mutations() { grep -E '^(curl |git .*clone|sdkmanager .*--licenses|sdkmanager .*--install|sudo |flutter .*precache)' "$CALLS" || true; }

mkdir -p "$TMP/payload/dart-sdk/bin"
printf '#!/bin/sh\necho "Dart SDK version: 3.13.2 (stable)"\n' > "$TMP/payload/dart-sdk/bin/dart"
chmod +x "$TMP/payload/dart-sdk/bin/dart"
printf '3.13.2\n' > "$TMP/payload/dart-sdk/version"
/usr/bin/python3 - "$TMP" <<'PY2'
import sys,pathlib,zipfile
p=pathlib.Path(sys.argv[1])
for name,entry in [('dart','dart-sdk/bin/dart'),('chromium','chrome-linux64/chrome'),('headless','chrome-headless-shell-linux64/chrome-headless-shell'),('ffmpeg','ffmpeg-linux')]:
 with zipfile.ZipFile(p/(name+'.zip'),'w') as z:
  if name=='dart':
   for f in (p/'payload/dart-sdk').rglob('*'):
    if f.is_file(): z.write(f,f.relative_to(p/'payload'))
  else: z.writestr(entry,'#!/bin/sh\necho "Chromium 151.0.7922.34"\n')
PY2
cat > "$TMP/bin/unzip" <<'SH2'
#!/bin/bash
echo "unzip $*" >> "$CALLS"
exec /usr/bin/unzip "$@"
SH2
chmod +x "$TMP/bin/unzip"

/usr/bin/python3 "$KIT_DIR/tests/flutter-cache-fixture.py" "$TMP"
