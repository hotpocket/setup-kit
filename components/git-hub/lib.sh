#!/bin/bash
# git hub — shared by the hub (07-components), the worker (03-headless §7) and
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
GIT_HUB_TOKEN_FILE="$(conf_get git_hub_forward_token "$HOME/.config/setup-kit/hub-forward-token" | sed "s|^~|$HOME|")"

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

# hub_token_check: the forward token's expiry, read from <token>.expires (one
# YYYY-MM-DD line, not secret; GitHub sets the date when the token is made).
# Warns git_hub_token_warn_days ahead, so a forward never first fails on the day.
hub_token_check() {
  local tok="$GIT_HUB_TOKEN_FILE" exp="$GIT_HUB_TOKEN_FILE.expires" d days
  local warn_days; warn_days="$(conf_get git_hub_token_warn_days 21)"
  [[ -s "$tok" ]] || return 0
  if [[ ! -s "$exp" ]]; then
    warn "git-hub forward token: expiry unknown — write its expiry date (YYYY-MM-DD, from GitHub's token page) to ${exp/#$HOME/\~}"
    return 0
  fi
  d="$(head -1 "$exp")"
  if [[ ! "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -u -d "$d" +%s >/dev/null 2>&1; then
    warn "git-hub forward token: ${exp/#$HOME/\~} is not a date (want one YYYY-MM-DD line; contents not shown, they may be secret)"; return 0
  fi
  # both as UTC midnights: local midnights straddling DST are 23 or 25 h apart
  days=$(( ($(date -u -d "$d" +%s) - $(date -u -d "$(date +%F)" +%s)) / 86400 ))
  if (( days < 0 )); then
    warn "git-hub forward token EXPIRED $d ($(( -days )) days ago) — forwards to GitHub fail while it stays. Make a new token (fine-grained, Contents read/write), replace ${tok/#$HOME/\~}, update ${exp/#$HOME/\~}"
  elif (( days <= warn_days )); then
    warn "git-hub forward token expires $d ($days days) — make a new token (fine-grained, Contents read/write), replace ${tok/#$HOME/\~}, update ${exp/#$HOME/\~}"
  else
    ok "git-hub forward token valid until $d ($days days)"
  fi
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
    do_or_say sudo usermod -aG "$GIT_HUB_USER" "$USER" && hint "takes effect at next login (git-hub uses sg or sudo -g meanwhile)"
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

# hub_release_units_ensure: user units that run `git-hub release` whenever the
# hub receives a push (a path unit on the receive log), with a timer as a
# backstop for a missed event. Written by content; install enables them.
hub_release_units_ensure() {
  local ud="$HOME/.config/systemd/user" drift=0 u want
  declare -A units=(
    [git-hub-release.service]="[Unit]
Description=git-hub release: forward content, open reviews for code, on hub main moving
[Service]
Type=oneshot
TimeoutStartSec=30min
Environment=PATH=%h/.local/bin:%h/bin:%h/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/git-hub release"
    [git-hub-release.path]="[Unit]
Description=git-hub release on every push the hub receives
[Path]
PathChanged=$GIT_HUB_ROOT/log/receive.jsonl
Unit=git-hub-release.service
[Install]
WantedBy=default.target"
    [git-hub-release.timer]="[Unit]
Description=git-hub release backstop, for a push whose event was missed
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Unit=git-hub-release.service
[Install]
WantedBy=timers.target"
  )
  for u in "${!units[@]}"; do
    want="${units[$u]}"
    [[ -f "$ud/$u" && "$(cat "$ud/$u")" == "$want" ]] && continue
    drift=1; warn "$u missing or drifted"
    (( INSTALL )) && { mkdir -p "$ud"; printf '%s\n' "$want" > "$ud/$u.tmp" && mv -f "$ud/$u.tmp" "$ud/$u"; log "wrote $ud/$u"; }
  done
  (( drift && INSTALL )) && systemctl --user daemon-reload
  # enablement is its own state: an install that died after writing the files
  # would otherwise read "current" forever and never start them
  for u in git-hub-release.path git-hub-release.timer; do
    systemctl --user is-enabled -q "$u" 2>/dev/null && systemctl --user is-active -q "$u" 2>/dev/null && continue
    drift=1; warn "$u not enabled and running"
    (( INSTALL )) && systemctl --user enable --now "$u" && log "$u: enabled"
  done
  # user units run only while the user manager does: without linger they stop at
  # logout and never start at boot, and the pushes come in as the hub user
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]]; then
    drift=1; warn "linger off for $USER: git-hub-release stops at logout and never starts at boot"
    (( INSTALL )) && loginctl enable-linger "$USER" && log "linger enabled for $USER"
  fi
  (( drift )) || ok "git-hub-release units current (reviews go to $(conf_get git_hub_review_thread 'nowhere: git_hub_review_thread unset'))"
}
