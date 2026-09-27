#!/bin/bash
# git hub — shared by the hub (07-components), the worker (03-headless §8) and
# the git-hub CLI. Spec: components/git-hub.md. Expects lib.sh already sourced.
#
# Both sides list repos like clone_repos: owner/repo[:path]. The bare repo is
# <basename>.git, owner/repo is its GitHub upstream, :path is where THIS host's
# working clone lives under $GIT_HOME.

GIT_HOME="${GIT_HOME:-$(dirname "$KIT_DIR")}"      # repos are siblings of the kit
GIT_HUB_REPOS="$(conf_get git_hub_repos '')"
GIT_HUB_USER="$(conf_get git_hub_user git)"
GIT_HUB_ROOT="$(conf_get git_hub_root /srv/git)"
GIT_HUB_UPSTREAM_BASE="$(conf_get git_hub_upstream_base git@github.com:)"

# hub_each <fn>: fn <name> <owner/repo> <clone dir> for every git_hub_repos entry
hub_each() {
  local e slug path
  for e in $GIT_HUB_REPOS; do
    slug="${e%%:*}"; path="${e#*:}"; [[ "$e" == *:* ]] || path="${slug##*/}"
    [[ "$slug" == */* ]] || { warn "git_hub_repos: bad entry '$e' (want owner/repo[:path])"; continue; }
    "$1" "${slug##*/}" "$slug" "$GIT_HOME/$path"
  done
}

# ------------------------------------------------------------------ hub side
# hub_keys_render <pushers file>: authorized_keys content. Every key gets
# `restrict` (no pty, no forwarding); options already on the line are kept.
hub_keys_render() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then echo "restrict $line"
    else echo "restrict,$line"; fi
  done < "$1"
}

# hub_git <args>: git as the hub user (sudo -u unless that is us)
hub_git() {
  if [[ "$GIT_HUB_USER" == "$(id -un)" ]]; then git "$@"; else sudo -u "$GIT_HUB_USER" git "$@"; fi
}
hub_as() {
  if [[ "$GIT_HUB_USER" == "$(id -un)" ]]; then "$@"; else sudo -u "$GIT_HUB_USER" "$@"; fi
}

# hub_repo_ensure <name> <owner/repo> <unused>: bare repo + its receive policy
hub_repo_ensure() {
  local name="$1" slug="$2" dir="$GIT_HUB_ROOT/$1.git" k v drift=0
  local -A want=(
    [receive.denyNonFastForwards]=true [receive.denyDeletes]=true [receive.fsckObjects]=true
    [core.hooksPath]="$GIT_HUB_ROOT/.hooks" [core.sharedRepository]=group
    [hub.upstream]="${GIT_HUB_UPSTREAM_BASE}${slug}.git"
  )
  if [[ ! -f "$dir/HEAD" ]]; then
    warn "bare repo $name.git missing ($slug)"
    (( INSTALL )) || return 0
    do_or_say hub_git init -q --bare --shared=group -b main "$dir" || { miss "git-hub: init $name.git"; return 1; }
  fi
  for k in "${!want[@]}"; do
    v="$(git --git-dir="$dir" config --get "$k" 2>/dev/null)"
    [[ "$v" == "${want[$k]}" ]] && continue
    drift=1
    if (( INSTALL )); then hub_git --git-dir="$dir" config "$k" "${want[$k]}"
    else warn "bare repo $name.git: $k is '${v:-unset}', want '${want[$k]}'"; fi
  done
  (( drift && INSTALL )) && log "bare repo $name.git: receive policy set"
  [[ -f "$dir/HEAD" ]] && ok "bare repo $name.git → ${want[hub.upstream]}"
}

# hub_hook_ensure: <root>/.hooks/post-receive, by content
hub_hook_ensure() {
  local src="$KIT_DIR/components/git-hub/post-receive" dst="$GIT_HUB_ROOT/.hooks/post-receive"
  if [[ -x "$dst" ]] && cmp -s "$src" "$dst"; then ok "post-receive hook current"; return 0; fi
  [[ -e "$dst" ]] && warn "post-receive hook drifted" || warn "post-receive hook missing"
  (( INSTALL )) || return 0
  hub_as mkdir -p "$GIT_HUB_ROOT/.hooks" "$GIT_HUB_ROOT/log"
  # read as us (the hub user may not reach the kit's checkout), owned by the hub user
  if [[ "$GIT_HUB_USER" == "$(id -un)" ]]; then install -m 0755 "$src" "$dst"
  else sudo install -m 0755 -o "$GIT_HUB_USER" -g "$GIT_HUB_USER" "$src" "$dst"; fi && log "wrote $dst"
}

# hub_keys_ensure <pushers file>: <root>/.ssh/authorized_keys, by content.
# Root-owned, so a push can never rewrite who may push.
hub_keys_ensure() {
  local pushers="$1" ak="$GIT_HUB_ROOT/.ssh/authorized_keys" want
  if [[ -z "$pushers" || ! -r "$pushers" ]]; then
    warn "git_hub_pushers '${pushers:-unset}' not readable — nobody can push"
    miss "git-hub: pushers file missing (one public key per line)"; return 0
  fi
  want="$(hub_keys_render "$pushers")"
  if [[ -f "$ak" && "$(cat "$ak")" == "$want" ]]; then
    ok "pushers: $(grep -c . <<<"$want") key(s), each restricted"; return 0
  fi
  [[ -f "$ak" ]] && warn "authorized_keys drifted from $pushers" || warn "authorized_keys missing ($pushers)"
  (( INSTALL )) || return 0
  sudo mkdir -p "$GIT_HUB_ROOT/.ssh"
  printf '%s\n' "$want" | sudo tee "$ak" >/dev/null
  sudo chown root:root "$GIT_HUB_ROOT/.ssh" "$ak"; sudo chmod 755 "$GIT_HUB_ROOT/.ssh"; sudo chmod 644 "$ak"
  log "wrote $ak from $pushers"
}

# hub_user_ensure: system user, git-shell login, home = root; the human in its group
hub_user_ensure() {
  local shell; shell="$(command -v git-shell || echo /usr/bin/git-shell)"
  if ! getent passwd "$GIT_HUB_USER" >/dev/null; then
    warn "hub user $GIT_HUB_USER missing"
    do_or_say sudo useradd --system --user-group --home-dir "$GIT_HUB_ROOT" --create-home --shell "$shell" "$GIT_HUB_USER"
  elif [[ "$(getent passwd "$GIT_HUB_USER" | cut -d: -f7)" != "$shell" ]]; then
    warn "hub user $GIT_HUB_USER login shell is not git-shell"
    [[ "$GIT_HUB_USER" == "$(id -un)" ]] || do_or_say sudo usermod -s "$shell" "$GIT_HUB_USER"
  else
    ok "hub user $GIT_HUB_USER: git-shell, home $GIT_HUB_ROOT"
  fi
  [[ "$GIT_HUB_USER" == "$(id -un)" ]] && return 0
  if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$GIT_HUB_USER"; then
    ok "$USER reads the hub (group $GIT_HUB_USER)"
  else
    warn "$USER is not in group $GIT_HUB_USER — git-hub status/forward/stage can't read the repos"
    do_or_say sudo usermod -aG "$GIT_HUB_USER" "$USER" && hint "takes effect at next login (git-hub uses sg meanwhile)"
  fi
}

# ------------------------------------------------------------------ worker side
GIT_HUB_KEY="$HOME/.ssh/git_hub"
_HUB_BEGIN="# >>> setup-kit git-hub (03-headless; edit git_hub= in the host conf, not this block)"
_HUB_END="# <<< setup-kit git-hub"

# hub_alias_want <host>: the managed ~/.ssh/config block
hub_alias_want() {
  printf '%s\nHost git-hub\n  HostName %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  IdentityAgent none\n  StrictHostKeyChecking accept-new\n%s\n' \
    "$_HUB_BEGIN" "$1" "$GIT_HUB_USER" "$GIT_HUB_KEY" "$_HUB_END"
}
_hub_alias_have() { [[ -f "$1" ]] && sed -n "\|^$_HUB_BEGIN\$|,\|^$_HUB_END\$|p" "$1"; }

# hub_alias_ensure <host>: key + block, by content; replaces the block in place
hub_alias_ensure() {
  local host="$1" cfg="$HOME/.ssh/config" want have
  if [[ -f "$GIT_HUB_KEY" ]]; then ok "git hub key ${GIT_HUB_KEY/#$HOME/\~}"
  else
    warn "git hub key ${GIT_HUB_KEY/#$HOME/\~} missing"
    if (( INSTALL )); then
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      do_or_say ssh-keygen -q -t ed25519 -N '' -C "git-hub:$(hostname)" -f "$GIT_HUB_KEY"
    fi
  fi
  [[ -f "$GIT_HUB_KEY.pub" ]] && hint "hub pushers file needs: $(cat "$GIT_HUB_KEY.pub")"
  want="$(hub_alias_want "$host")"; have="$(_hub_alias_have "$cfg")"
  if [[ "$have" == "$want" ]]; then ok "git-hub alias → $host"; return 0; fi
  [[ -n "$have" ]] && warn "git-hub alias points elsewhere — reconciling to $host" \
                   || warn "git-hub alias missing (→ $host)"
  (( INSTALL )) || return 0
  mkdir -p "$HOME/.ssh"; touch "$cfg"
  if [[ -n "$have" ]]; then
    local tmp; tmp="$(mktemp)"; printf '%s\n' "$want" > "$tmp.blk"
    awk -v b="$_HUB_BEGIN" -v e="$_HUB_END" -v f="$tmp.blk" '
      $0==b {skip=1; while ((getline l < f) > 0) print l; next}
      $0==e {skip=0; next}
      !skip' "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
    rm -f "$tmp" "$tmp.blk"
  else
    { [[ -s "$cfg" ]] && echo; printf '%s\n' "$want"; } >> "$cfg"
  fi
  chmod 600 "$cfg"; log "git-hub alias → $host"
}

# hub_remote_ensure <name> <owner/repo> <clone>: origin → git-hub:<name>.git,
# the previous origin kept as `github`. Then probe the hub through it.
hub_remote_ensure() {
  local name="$1" slug="$2" clone="$3" want="git-hub:$1.git" cur
  if [[ ! -d "$clone/.git" ]]; then
    warn "git hub: $slug has no clone at ${clone/#$HOME/\~} — nothing to re-point"; return 0
  fi
  cur="$(git -C "$clone" remote get-url origin 2>/dev/null)"
  if [[ "$cur" != "$want" ]]; then
    warn "git hub: $name origin is ${cur:-unset}, want $want"
    (( INSTALL )) || return 0
    if [[ -n "$cur" ]] && ! git -C "$clone" remote get-url github >/dev/null 2>&1; then
      git -C "$clone" remote add github "$cur"
    fi
    if [[ -n "$cur" ]]; then git -C "$clone" remote set-url origin "$want"
    else git -C "$clone" remote add origin "$want"; fi
    log "$name: origin → $want (was ${cur:-unset}; kept as remote github)"
  fi
  if timeout 20 git -C "$clone" ls-remote origin >/dev/null 2>&1; then
    ok "$name: origin is the hub ($want)"
  else
    warn "git hub: $name — the hub does not answer for $want (key not in its pushers, repo missing, or unreachable)"
    miss "git-hub: $name unreachable through git-hub"
  fi
}
