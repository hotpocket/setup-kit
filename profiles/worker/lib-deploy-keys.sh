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
#
# git_auth=token is the other mode: ONE fine-grained personal access token,
# restricted to "only select repositories", fed to `gh auth login --with-token`
# from a file you place (never the conf, never a repo). gh's credential helper
# then serves every https github.com URL. Right when a box touches more than a
# couple of repos, or when the job must PUSH (a PAT's permissions are uniform
# across its selected repos, so a read-only repo and a read-write repo can't
# share one token).
#
# The modes MIX: git_auth="deploy-keys token" — e.g. .configs pulled read-only
# by a deploy key, the job's repos over https by a read-write PAT. Which repo
# goes which way is decided per URL: a repo named in deploy_repos clones over
# its alias, anything else over https via the token.

GIT_AUTH="$(conf_get git_auth deploy-keys)"       # deploy-keys | token | "deploy-keys token"
auth_has() { [[ " $GIT_AUTH " == *" $1 "* ]]; }
DEPLOY_REPOS="$(conf_get deploy_repos '')"
TOKEN_FILE="$(conf_get github_token_file "$HOME/.config/setup-kit/github-token")"; TOKEN_FILE="${TOKEN_FILE/#\~/$HOME}"
CLONE_REPOS="$(conf_get clone_repos '')"          # owner/repo[:dest] ... → ~/git/<dest|repo>

# token_rewrite_ssh: a manifest that names remotes as git@github.com:o/r.git
# (audiobook's repos.yml does) would need an account ssh key this box must not
# have. Rewrite that prefix to https so gh's credential helper serves it. The
# deploy-key aliases (git@github.com-<name>:) don't match the prefix — the
# colon is part of it — so they are untouched. Idempotent; install writes it.
token_rewrite_ssh() {
  local want="git@github.com:" have
  have="$(git config --global --get-all url.https://github.com/.insteadOf 2>/dev/null | grep -Fx "$want" || true)"
  if [[ -n "$have" ]]; then ok "git: ssh github remotes rewritten to https (token serves them)"; return 0; fi
  warn "git: git@github.com: remotes not rewritten to https — manifests naming ssh remotes can't clone"
  (( INSTALL )) && do_or_say git config --global --add url.https://github.com/.insteadOf "$want"
}

# repo_slug <url>: https://github.com/o/r.git | git@github.com-x:o/r.git → o/r
repo_slug() { sed -E 's#^(https://github.com/|git@[^:]+:)##; s#\.git$##' <<<"$1"; }
# deploy_name_for <owner/repo>: the deploy_repos name covering it, if any
deploy_name_for() {
  local entry
  for entry in $DEPLOY_REPOS; do [[ "${entry#*=}" == "$1" ]] && { echo "${entry%%=*}"; return 0; }; done
  return 1
}

# token_login: gh authenticated? else log in from the token file (install).
# Never prints the token. Returns 0 when gh can talk to GitHub.
token_login() {
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not installed — needed to hold the token"; return 1
  fi
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "gh authenticated ($(gh api user --jq .login 2>/dev/null || echo '?'))"
    gh auth setup-git >/dev/null 2>&1 || true      # idempotent credential helper
    token_rewrite_ssh
    return 0
  fi
  if [[ ! -s "$TOKEN_FILE" ]]; then
    warn "gh not authenticated and no token file at ${TOKEN_FILE/#$HOME/\~}"
    hint "github.com → Settings › Developer settings › Fine-grained tokens: only select repos, Contents: read-only"
    hint "then on this box:  mkdir -p $(dirname "${TOKEN_FILE/#$HOME/\~}") && (umask 077; cat > ${TOKEN_FILE/#$HOME/\~})   # paste, Ctrl-D"
    miss "creds: github token file ${TOKEN_FILE/#$HOME/\~} missing"
    return 1
  fi
  [[ "$(stat -c %a "$TOKEN_FILE")" == 600 ]] || { chmod 600 "$TOKEN_FILE"; log "chmod 600 ${TOKEN_FILE/#$HOME/\~}"; }
  (( INSTALL )) || { warn "token file present; install logs gh in with it"; return 1; }
  if gh auth login --hostname github.com --git-protocol https --with-token < "$TOKEN_FILE" 2>>"$LOG_DIR/${SCRIPT_NAME:-worker}.log" \
     && gh auth setup-git; then
    ok "gh logged in from token file ($(gh api user --jq .login 2>/dev/null || echo '?')); credential helper set"
    token_rewrite_ssh
    return 0
  fi
  warn "gh auth login --with-token failed (expired or malformed token?)"
  miss "creds: github token rejected"
  return 1
}

# token_probe <owner/repo>: can the token READ this repo? (metadata call)
token_probe() {
  if gh repo view "$1" --json name >/dev/null 2>&1; then ok "token reaches $1"
  else warn "token cannot read $1 — add it to the token's selected repositories"; miss "creds: token lacks $1"; fi
}

# clone_repos: every owner/repo lands in ~/git/<repo>, or ~/git/<path> when
# written owner/repo:path (a manifest may want it nested — books lives at
# landry.bot/books). A repo that has a deploy key (deploy_repos) clones over
# its alias; the rest over https, which only works when the token mode is on —
# otherwise say so instead of failing an https clone with no credential.
clone_wanted() {
  local e r dest name url
  for e in $CLONE_REPOS; do
    r="${e%%:*}"; dest="${e#*:}"; [[ "$e" == *:* ]] || dest="${r##*/}"
    dest="$HOME/git/$dest"
    if [[ -d "$dest/.git" ]]; then ok "repo $r at ${dest/#$HOME/\~}"; continue; fi
    if name="$(deploy_name_for "$r")"; then url="$(deploy_url "$name" "$r")"
    elif auth_has token; then url="https://github.com/$r.git"
    else
      warn "repo $r: no deploy key in deploy_repos and git_auth has no token — nothing can clone it"
      miss "clone: $r (no credential)"; continue
    fi
    warn "repo $r not cloned"
    (( INSTALL )) && { mkdir -p "$(dirname "$dest")"; do_or_say git clone "$url" "$dest" || miss "clone: $r"; }
  done
}

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
