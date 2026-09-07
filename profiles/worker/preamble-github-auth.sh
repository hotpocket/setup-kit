#!/bin/bash
# GitHub auth preamble for a WORKER — run once by bootstrap.sh before the
# phase loop. The workstation preamble front-loads YubiKey PIN + touches and
# pins github to FIDO2 keys; none of that belongs on a box where jobs run
# with nobody present. Here:
#   1. pin GitHub's published host keys (no TOFU prompt mid-run)
#   2. a github.com stanza over 443 that offers the plain deploy key if present
#   3. clone private .configs; on failure offer `gh auth login` (device flow —
#      the code is entered in a browser on ANY machine, no local GUI needed)
SCRIPT_NAME="wk-preamble-github-auth"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

REPO="$(conf_get configs_repo 'git@github.com:hotpocket/.configs.git')"
DEST="$HOME/git/.configs"
KEY="$(conf_get git_deploy_key "$HOME/.ssh/id_ed25519_worker")"; KEY="${KEY/#\~/$HOME}"

section "github auth preamble ($MODE) — worker"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

# ---- 1. host keys: GitHub's published values (pinned constants, not a
# keyscan — a keyscan trusts whoever answers the wire). Same set as the
# workstation preamble; update both when GitHub rotates.
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
    if (( INSTALL )); then echo "$host $k" >> "$HOME/.ssh/known_hosts"; seeded=1
    else warn "known_hosts: $host ${k%% *} not pinned"; fi
  done
done
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true
(( seeded )) && log "pinned GitHub host keys into known_hosts"
ok "known_hosts: GitHub host keys"

# ---- 2. ssh config stanza: 443 (port 22 is firewall-bait), agent-free, the
# deploy key offered when it exists. No IdentitiesOnly lock: until the deploy
# key is registered, whatever key you copied in for bootstrapping still works.
CFG="$HOME/.ssh/config"
if ! grep -qE '^[[:space:]]*Host[[:space:]]+github\.com' "$CFG" 2>/dev/null; then
  if (( INSTALL )); then
    { echo
      echo "Host github.com"
      echo "  HostName ssh.github.com"
      echo "  Port 443"
      echo "  PreferredAuthentications publickey"
      echo "  IdentityAgent none"
      echo "  IdentityFile $KEY"
    } >> "$CFG"
    chmod 600 "$CFG"
    log "wrote github.com stanza (deploy key ${KEY/#$HOME/\~})"
  else
    warn "~/.ssh/config: no github.com stanza"
  fi
else
  ok "ssh config: github.com stanza present"
fi

# ---- 3. clone .configs ------------------------------------------------------
if [[ -d "$DEST/.git" ]]; then ok ".configs already cloned"; exit 0; fi
if (( ! INSTALL )); then warn ".configs not cloned (install will clone / prompt for auth)"; exit 0; fi
try_clone() { mkdir -p "$(dirname "$DEST")"; git clone "$REPO" "$DEST" 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"; [[ -d "$DEST/.git" ]]; }
log "cloning .configs..."
try_clone && { ok ".configs cloned"; exit 0; }
# One deploy key opens ONE repo on GitHub, so the job repo's key can't clone
# .configs. Fall back to gh's device flow over https: it prints a URL and a
# code; open them in a browser anywhere (laptop, phone) — nothing local.
if [[ -t 0 ]] && command -v gh >/dev/null 2>&1; then
  warn "ssh clone failed — .configs is private and this key can't open it"
  read -rp "Authenticate with GitHub via device code (gh auth login, browser on any machine)? [Y/n] " a
  if [[ ! "$a" =~ ^[Nn] ]]; then
    gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git \
      && REPO="https://github.com/${REPO#git@github.com:}" && try_clone \
      && { ok ".configs cloned over https (gh token)"; exit 0; }
  fi
fi
fail "no GitHub auth — .configs not cloned (phases still run; phase 06 will retry)"
miss "preamble: github auth"
exit 0
