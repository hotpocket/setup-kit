#!/bin/bash
# GitHub auth preamble — run ONCE by bootstrap.sh BEFORE the phase loop,
# while a human is still at the keyboard. Front-loads every interactive bit
# (YubiKey PIN + touches, fallback gh login) so the phases run unaided:
#
#   1. pin GitHub's published host keys into known_hosts (no TOFU prompt)
#   2. write the ~/.ssh/config github-over-443 stanza if absent
#   3. clone private .configs NOW; on auth failure recover resident FIDO2
#      keys from a plugged YubiKey (ssh-keygen -K: PIN + touch), retry,
#      then fall back to gh auth login
#
# NOT a numbered phase on purpose: every ssh signature with an *-sk key
# costs a physical touch, so this must run exactly once, not once per pass.
# Phase 06 stays as the idempotent fallback for runs that skip bootstrap.
SCRIPT_NAME="ws-preamble-github-auth"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

REPO="$(conf_get configs_repo 'git@github.com:hotpocket/.configs.git')"
DEST="$HOME/git/.configs"

section "github auth preamble ($MODE)"
[[ "$REPO" == git@github.com:* ]] || { ok "configs_repo is not github-ssh — nothing to do"; exit 0; }

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

# gnome-keyring / gcr ssh-agent can't sign FIDO2 (-sk) keys and silently refuses
# ("agent refused operation"), shadowing a working YubiKey — and it intercepts
# SSH_AUTH_SOCK ahead of any real agent. Mask it so ssh talks to the security
# key directly. User-level + reversible; the already-running agent persists
# until next login, so the github auth below also sets IdentityAgent none to
# bypass any agent regardless of login state.
disable_gnome_ssh_agent() {
  (( INSTALL )) || return 0
  command -v systemctl >/dev/null 2>&1 && systemctl --user mask --now \
    gcr-ssh-agent.socket gcr-ssh-agent.service >/dev/null 2>&1 || true
  local src=/etc/xdg/autostart/gnome-keyring-ssh.desktop
  local dst="$HOME/.config/autostart/gnome-keyring-ssh.desktop"
  if [[ -f "$src" ]] && { [[ ! -f "$dst" ]] || ! grep -q '^Hidden=true' "$dst"; }; then
    mkdir -p "$HOME/.config/autostart"
    cp "$src" "$dst" && printf '\nHidden=true\nX-GNOME-Autostart-enabled=false\n' >> "$dst"
    log "disabled gnome-keyring ssh agent (effective next login)"
  fi
}
disable_gnome_ssh_agent

# Path of a resident FIDO2 (-sk) key recovered from a YubiKey, if one exists —
# this is the preferred github identity. Prints nothing / returns 1 if none.
gh_resident_key() {
  local f
  for f in "$HOME"/.ssh/id_*_sk_rk*; do
    [[ -f "$f" && "$f" != *.pub ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# ---- 1. host keys: GitHub's published values, for both the real host and
# the ssh-over-443 alias. Pinned constants, NOT ssh-keyscan — a keyscan
# trusts whoever answers the wire. (ed25519 fingerprint:
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU)
GH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
  "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
)
seeded=0
for host in "github.com" "[ssh.github.com]:443"; do
  for k in "${GH_KEYS[@]}"; do
    blob="${k#* }"
    ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | grep -qF "$blob" && continue
    if (( INSTALL )); then
      echo "$host $k" >> "$HOME/.ssh/known_hosts"; seeded=1
    else
      warn "known_hosts: $host ${k%% *} not pinned"
    fi
  done
done
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true
(( seeded )) && log "pinned GitHub host keys into known_hosts"
ok "known_hosts: GitHub host keys"

# ---- 2. ssh config stanza (443 — port 22 is firewall-bait). When a YubiKey
# resident key is present, lock github to it: IdentitiesOnly + IdentityAgent
# none => ONLY that key is offered and no agent is consulted, so no stray key
# (e.g. an unrelated dbswebsite key) is tried and a refusing gnome-keyring can't
# intercept. Without an -sk key we leave the stanza agent-friendly (a passphrase
# key loaded in an agent still works). This reconciles every run — it no longer
# matters that .configs may already be cloned.
CFG="$HOME/.ssh/config"
GH_SK="$(gh_resident_key || true)"
if ! grep -qE '^[[:space:]]*Host[[:space:]]+github\.com' "$CFG" 2>/dev/null; then
  if (( INSTALL )); then
    { echo
      echo "Host github.com"
      echo "  HostName ssh.github.com"
      echo "  Port 443"
      echo "  PreferredAuthentications publickey"
      if [[ -n "$GH_SK" ]]; then
        echo "  IdentitiesOnly yes"
        echo "  IdentityAgent none"
        echo "  IdentityFile $GH_SK"
      fi
    } >> "$CFG"
    chmod 600 "$CFG"
    log "wrote github.com stanza${GH_SK:+ (pinned $GH_SK)}"
  else
    warn "~/.ssh/config: no github.com stanza"
  fi
else
  ok "ssh config: github.com stanza present"
  # idempotently pin a resident key into an existing stanza if absent
  if [[ -n "$GH_SK" ]] && ! grep -qF "IdentityFile $GH_SK" "$CFG"; then
    if (( INSTALL )); then
      sed -i "/^Host github\.com$/a\\  IdentitiesOnly yes\n  IdentityAgent none\n  IdentityFile $GH_SK" "$CFG"
      log "pinned resident key in existing github stanza ($GH_SK)"
    else
      warn "github stanza present but resident key $GH_SK not pinned"
    fi
  fi
fi

# ---- 3. auth + clone, minimum touches: just TRY the clone — a separate
# "does auth work" probe would cost its own touch.
try_clone() { mkdir -p "$(dirname "$DEST")"; git clone "$REPO" "$DEST" 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"; [[ -d "$DEST/.git" ]]; }

if [[ -d "$DEST/.git" ]]; then
  ok ".configs already cloned — no auth needed this run"
  exit 0
fi
if (( ! INSTALL )); then
  warn ".configs not cloned (install will handle auth + clone)"
  exit 0
fi

log "cloning .configs (touch the YubiKey if it blinks)..."
if try_clone; then ok ".configs cloned"; exit 0; fi

# clone failed → recover resident keys from a plugged security key
if lsusb 2>/dev/null | grep -qiE 'yubico|fido'; then
  warn "clone failed — recovering resident ssh keys from YubiKey (PIN, then touch)"
  (cd "$HOME/.ssh" && ssh-keygen -K) || warn "ssh-keygen -K failed (keys not resident on this YubiKey?)"
  found=0
  for f in "$HOME"/.ssh/id_*_sk_rk*; do
    [[ -f "$f" && "$f" != *.pub ]] || continue
    chmod 600 "$f"; found=1
    grep -qF "IdentityFile $f" "$HOME/.ssh/config" 2>/dev/null \
      || sed -i "/^Host github\.com$/a\\  IdentitiesOnly yes\n  IdentityAgent none\n  IdentityFile $f" "$HOME/.ssh/config"
  done
  if (( found )); then
    log "recovered key(s) pinned in ssh config — retrying clone (touch again)"
    try_clone && { ok ".configs cloned (recovered resident key)"; exit 0; }
  fi
fi

# last resort: browser flow
if [[ -t 0 ]] && command -v gh >/dev/null 2>&1; then
  read -rp "No working ssh key. Authenticate with GitHub in a browser (gh auth login)? [Y/n] " a
  if [[ ! "$a" =~ ^[Nn] ]]; then
    gh auth login && gh auth setup-git && try_clone && { ok ".configs cloned (gh auth)"; exit 0; }
  fi
fi

fail "no GitHub auth — .configs not cloned (phases still run; phase 06 will retry)"
miss "preamble: github auth"
exit 0
