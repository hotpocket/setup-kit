#!/bin/bash
# Per-repo GitHub deploy keys for a worker — sourced by the preamble (once,
# before anything is cloned) and by 03-headless (every pass, as the doctor).
# Not a phase: the name doesn't match bootstrap's [0-9][0-9]*-*.sh glob.
#
# GitHub's rule drives the shape: a deploy key opens exactly ONE repo. So each
# private repo the box pulls gets its own ed25519 key and its own ssh alias,
#     Host github.com-<name>  →  IdentityFile ~/.ssh/deploy_<name>
# and clone URLs use the alias: git@github.com-<name>:owner/repo.git. Keys are
# read-only unless you tick "allow write" when registering. No account key,
# no YubiKey (a cron can't touch one), nothing that opens more than it must.
#
# Host conf:  deploy_repos="configs=hotpocket/.configs audiobook=owner/repo"
# Expects lib.sh already sourced (conf_get, ok/warn/log, INSTALL, do_or_say).

DEPLOY_REPOS="$(conf_get deploy_repos '')"

# deploy_each <fn>: call fn <name> <owner/repo> <keyfile> for every entry
deploy_each() {
  local entry name repo
  for entry in $DEPLOY_REPOS; do
    name="${entry%%=*}"; repo="${entry#*=}"
    [[ -n "$name" && "$repo" == */* ]] || { warn "deploy_repos: bad entry '$entry' (want name=owner/repo)"; continue; }
    "$1" "$name" "$repo" "$HOME/.ssh/deploy_$name"
  done
}

# deploy_ensure <name> <repo> <key>: keypair on disk + ssh alias stanza.
# Generating the keypair is local and harmless; REGISTERING the public half on
# the repo is yours (Settings › Deploy keys). Install mode only.
deploy_ensure() {
  local name="$1" repo="$2" key="$3" cfg="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [[ -f "$key" ]]; then
    ok "deploy key $name: ${key/#$HOME/\~} ($repo)"
  else
    warn "deploy key $name missing: ${key/#$HOME/\~} ($repo)"
    if (( INSTALL )); then
      do_or_say ssh-keygen -q -t ed25519 -N '' -C "deploy:$repo@$(hostname)" -f "$key" \
        && log "generated — register ${key/#$HOME/\~}.pub on github.com/$repo → Settings › Deploy keys"
    fi
  fi
  if grep -qE "^[[:space:]]*Host[[:space:]]+github\.com-$name\$" "$cfg" 2>/dev/null; then
    ok "ssh alias github.com-$name"
  elif (( INSTALL )); then
    { echo
      echo "Host github.com-$name"
      echo "  # setup-kit worker deploy key for $repo (one key = one repo)"
      echo "  HostName ssh.github.com"
      echo "  Port 443"
      echo "  User git"
      echo "  IdentityFile $key"
      echo "  IdentitiesOnly yes"
      echo "  IdentityAgent none"
    } >> "$cfg"
    chmod 600 "$cfg"
    log "wrote ssh alias github.com-$name → ${key/#$HOME/\~}"
  else
    warn "ssh alias github.com-$name not in ~/.ssh/config"
  fi
}

# deploy_probe <name> <repo> <key>: does GitHub accept the key, and for THIS
# repo? A deploy key answers "Hi owner/repo! You've successfully
# authenticated"; an account key would say "Hi username!". Read-only, no clone.
deploy_probe() {
  local name="$1" repo="$2" key="$3" out
  [[ -f "$key" ]] || return 0                       # deploy_ensure already warned
  out="$(timeout 20 ssh -o BatchMode=yes -T "git@github.com-$name" 2>&1 || true)"
  if [[ "$out" == *"Hi $repo!"*"successfully authenticated"* ]]; then
    ok "deploy key $name accepted by GitHub for $repo"
  elif [[ "$out" == *"successfully authenticated"* ]]; then
    warn "deploy key $name authenticates but not as $repo: ${out%%\!*}!"
  else
    warn "GitHub does not accept deploy key $name yet ($repo)"
    hint "register: cat ${key/#$HOME/\~}.pub  →  github.com/$repo/settings/keys  (read-only unless the job pushes)"
    miss "creds: deploy key $name not registered on $repo"
  fi
}

# deploy_url <name> <repo>: the alias clone URL
deploy_url() { echo "git@github.com-$1:$2.git"; }
