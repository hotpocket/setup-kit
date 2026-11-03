#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/memory-fixture.sh"
export KIT_TOOL_ROOT="$ROOT" GIT_HOME="$HOME/repos" FIXTURE="$TMP"
mkdir -p "$GIT_HOME" "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin/java"
chmod +x "$ROOT/usr/lib/jvm/java-21-openjdk-amd64/bin/java"
for c in curl git sdkmanager apt-get dpkg-query sha256sum; do
  cat > "$TMP/bin/$c" <<'PY'
#!/usr/bin/python3
import os,sys,pathlib,shutil,subprocess
p=pathlib.Path; args=sys.argv[1:]; name=p(sys.argv[0]).name
with open(os.environ['CALLS'],'a') as f: f.write(name+' '+' '.join(args)+'\n')
s=p(os.environ['STATE']); home=p(os.environ['HOME'])
if name=='curl':
 if (s/'curl-fail').exists(): sys.exit(22)
 url=next(a for a in args if a.startswith('https:')); dest=args[args.index('-o')+1]
 src='uv.tar.gz' if 'uv-' in url else 'blender.tar.xz' if 'blender-' in url else 'android.zip'
 shutil.copyfile(p(os.environ['FIXTURE'])/src,dest)
elif name=='sha256sum':
 line=sys.stdin.read(); (s/'checksum-input').write_text(line)
 sys.exit(1 if (s/'checksum-fail').exists() else 0)
elif name=='git':
 if 'clone' in args:
  d=p(args[-1]); (d/'.git').mkdir(parents=True); (d/'bin/cache').mkdir(parents=True)
  (d/'bin/flutter').write_text('#!/bin/sh\necho "flutter $*" >> "$CALLS"\nmkdir -p "$HOME/development/flutter/bin/cache"\nprintf \'{"frameworkVersion":"3.47.2","dartSdkVersion":"3.13.2"}\\n\' > "$HOME/development/flutter/bin/cache/flutter.version.json"\n')
  (d/'bin/flutter').chmod(0o755); (d/'HEAD').write_text('d3b14c876900e553bc736ca19295fc09e3853e8e')
 elif 'rev-parse' in args:
  d=p(args[args.index('-C')+1]); print((d/'HEAD').read_text() if (d/'HEAD').exists() else 'abc123')
 elif 'status' in args: pass
elif name=='sdkmanager':
 if '--licenses' in args:
  (home/'Android/Sdk/licenses').mkdir(parents=True,exist_ok=True)
  (home/'Android/Sdk/licenses/android-sdk-license').write_text('accepted\n')
 else:
  for a in args:
   if a.startswith('-'): continue
   d=home/'Android/Sdk'/a.replace(';','/'); d.mkdir(parents=True,exist_ok=True)
   (d/'source.properties').write_text(('AndroidVersion.ApiLevel=36' if a=='platforms;android-36' else 'Pkg.Revision='+('36.0.0' if a=='platform-tools' else a.split(';')[-1]))+'\n')
elif name=='dpkg-query':
 pkg=args[-1]; print(((s/'ca-version').read_text().strip() if (s/'ca-version').exists() else '20260816ubuntu0.26.04.1') if pkg=='ca-certificates' else 'install ok installed' if (s/('pkg-'+pkg)).exists() else '')
 sys.exit(0 if pkg=='ca-certificates' or (s/('pkg-'+pkg)).exists() else 1)
elif name=='apt-get':
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
# Download fixtures contain executable behaviour, not mocks of component functions.
mkdir -p "$TMP/payload/uv-x86_64-unknown-linux-gnu" "$TMP/payload/blender-5.2.2-linux-x64" "$TMP/payload/cmdline-tools/bin"
printf '#!/bin/sh\necho "uv 0.12.23"\n' > "$TMP/payload/uv-x86_64-unknown-linux-gnu/uv"
printf '#!/bin/sh\necho "uvx 0.12.23"\n' > "$TMP/payload/uv-x86_64-unknown-linux-gnu/uvx"
printf '#!/bin/sh\necho "Blender 5.2.2 LTS"\n' > "$TMP/payload/blender-5.2.2-linux-x64/blender"
printf '#!/bin/sh\nexec "$FIXTURE/bin/sdkmanager" "$@"\n' > "$TMP/payload/cmdline-tools/bin/sdkmanager"
printf 'Pkg.Revision=22.0\n' > "$TMP/payload/cmdline-tools/source.properties"
chmod +x "$TMP/payload"/*/{uv,uvx,blender} "$TMP/payload/cmdline-tools/bin/sdkmanager" 2>/dev/null || true
/usr/bin/tar -czf "$TMP/uv.tar.gz" -C "$TMP/payload" uv-x86_64-unknown-linux-gnu
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
