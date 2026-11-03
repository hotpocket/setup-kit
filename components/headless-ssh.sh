#!/bin/bash
# Internal to Flutter headless: OpenSSH accepts only these four user variables.
SSH_ENV="$HOME/.ssh/environment"
SSH_CONF="$TOOL_ROOT/etc/ssh/sshd_config.d/60-setup-kit-headless.conf"
SSH_WANT='PermitUserEnvironment PATH,ANDROID_HOME,ANDROID_SDK_ROOT,JAVA_HOME'
SSH_MARKER="$HOME/.config/setup-kit/headless-ssh.active"
SSH_HASH=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$SSH_WANT")
SSH_PATH="$HOME/.local/bin:$HOME/.bun/bin:$FLUTTER_DIR/bin:$JAVA_DIR/bin:$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
headless_ssh_env() {
  python3 -I - "$SSH_ENV" "$MODE" "$SDK_DIR" "$JAVA_DIR" "$SSH_PATH" <<'PY'
import os,sys,tempfile
from pathlib import Path
path=Path(sys.argv[1]); wanted=dict(ANDROID_HOME=sys.argv[3],ANDROID_SDK_ROOT=sys.argv[3],JAVA_HOME=sys.argv[4],PATH=sys.argv[5])
if path.is_symlink(): sys.exit('SSH environment is externally managed; update its owner')
old=path.read_text() if path.exists() else ''
lines=old.splitlines(); actual={}
for l in lines:
 k,sep,v=l.partition('=')
 if sep: actual[k]=v
if all(actual.get(k)==v for k,v in wanted.items()) and path.stat().st_mode & 0o777 == 0o600: sys.exit(0)
if sys.argv[2]=='check': sys.exit(1)
lines=[l for l in lines if l.partition('=')[0] not in wanted]
lines += [k+'='+v for k,v in wanted.items()]
path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd,name=tempfile.mkstemp(prefix='.environment.',dir=path.parent)
try:
 with os.fdopen(fd,'w') as f: f.write('\n'.join(lines)+'\n')
 os.chmod(name,0o600); os.replace(name,path)
finally:
 if os.path.exists(name): os.unlink(name)
PY
}
headless_ssh_config() (
  # Keep the previous owned file until validation succeeds. Reload, never stop.
  work=$(mktemp -d "$HOME/.ssh-config.XXXXXX") || exit 1
  trap 'rm -rf "$work"' EXIT
  printf '%s\n' "$SSH_WANT" > "$work/config" || exit 1
  rm -f "$SSH_MARKER" || exit 1
  sudo mkdir -p "$(dirname "$SSH_CONF")" || exit 1
  dest=$(sudo mktemp "$SSH_CONF.XXXXXX") || exit 1
  had_old=0
  if [[ -f "$SSH_CONF" ]]; then sudo cp -p "$SSH_CONF" "$work/old" || exit 1; had_old=1; fi
  sudo install -m 644 "$work/config" "$dest" && sudo mv -Tf "$dest" "$SSH_CONF" || exit 1
  if ! sudo /usr/sbin/sshd -t || ! sudo /usr/sbin/sshd -T | grep -Fx 'permituserenvironment PATH,ANDROID_HOME,ANDROID_SDK_ROOT,JAVA_HOME' >/dev/null; then
    if (( had_old )); then sudo cp -p "$work/old" "$dest" && sudo mv -Tf "$dest" "$SSH_CONF"; else sudo rm -f "$SSH_CONF"; fi
    echo 'SSH config invalid; restored prior file, daemon not reloaded' >&2; exit 1
  fi
  sudo systemctl reload ssh.service && tool_write "$SSH_HASH" "$SSH_MARKER"
)
if MODE=check headless_ssh_env; then ok "headless SSH environment"
else
  warn "headless SSH environment missing or drifted"
  do_or_say headless_ssh_env || miss "flutter: SSH environment write failed"
fi
if [[ -f "$SSH_CONF" && ! -L "$SSH_CONF" && "$(cat "$SSH_CONF")" == "$SSH_WANT" && "$(stat -c %a "$SSH_CONF")" == 644 \
      && "$(cat "$SSH_MARKER" 2>/dev/null)" == "$SSH_HASH" ]]; then
  ok "headless SSH environment allowlist"
else
  warn "headless SSH environment allowlist missing or drifted"
  do_or_say headless_ssh_config || miss "flutter: SSH environment allowlist failed; inspect sshd configuration"
fi
