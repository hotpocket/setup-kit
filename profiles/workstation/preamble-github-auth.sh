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
# `recover` — enrol the PLUGGED YubiKey on an already-provisioned machine:
# recover its resident key (PIN + touch), pin it, prove auth. The clone
# fallback below only runs when .configs is NOT cloned, so without this mode a
# second token could never be added on a box that already had .configs
# (2026-09-14: primary plugged, stanza pinned only the backup's credential,
# every pull died FIDO_ERR_NO_CREDENTIALS, the fix lived in the unpullable repo).
# `copy <user@host[:~/.ssh]>` — copy github FIDO2 (-sk) stub pairs from a
# known box via one ssh tar stream (never overwrites existing files), keeping
# only `sk-ssh-ed25519@openssh.com ... ssh:github` pairs, then pin them.
SCRIPT_NAME="ws-preamble-github-auth"
source "$(dirname "$0")/../../lib.sh"
require_user
RECOVER=0
COPY=0
COPY_SRC=""
if [[ "${1:-}" == recover ]]; then
  RECOVER=1; set -- install
elif [[ "${1:-}" == copy ]]; then
  COPY=1; COPY_SRC="${2:-}"
  [[ -n "$COPY_SRC" ]] || { echo "usage: $0 copy <user@host[:~/.ssh]>" >&2; exit 2; }
  set -- install
fi
init_mode "${1:-}"

REPO="$(conf_get configs_repo 'git@github.com:hotpocket/.configs.git')"
DEST="$HOME/git/.configs"
if [[ "$(conf_get configs_role full)" == agent || "$(conf_get git_auth '')" == none ]]; then
  GIT_HOME="${GIT_HOME:-$(dirname "$KIT_DIR")}"; DEST="$GIT_HOME/.configs"
fi

section "github auth preamble ($MODE)"
# configs=no: a box that isn't the kit owner's (no private .configs, no YubiKey).
# Nothing to clone, and the GNOME ssh agent stays — it is the user's, and the
# masking below exists only for the owner's FIDO2 keys.
if [[ "$(conf_get configs yes)" == no ]]; then
  ok "configs=no — no .configs to clone; GitHub auth is the user's own (gh auth login)"
  exit 0
fi
if [[ "$(conf_get git_auth '')" == none ]]; then
  ok "git_auth=none — GitHub authentication, host keys and agent changes skipped"
  [[ -d "$DEST/.git" ]] && { ok ".configs already cloned"; exit 0; }
  (( INSTALL )) || { warn ".configs not cloned — phase 06 retries the configured source"; exit 0; }
  mkdir -p "$(dirname "$DEST")"
  if git clone "$REPO" "$DEST" >> "$LOG_DIR/$SCRIPT_NAME.log" 2>&1 && [[ -d "$DEST/.git" ]]; then
    ok ".configs cloned"
  else
    warn ".configs unavailable — phase 06 retries (check configs_repo and hub access)"
  fi
  exit 0
fi
(( COPY || RECOVER )) || [[ "$REPO" == git@github.com:* ]] || { ok "configs_repo is not github-ssh — nothing to do"; exit 0; }

(( INSTALL )) && { mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; }

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
(( COPY )) || disable_gnome_ssh_agent

# Canonical filename per YubiKey serial for the recovered github sk key.
# Both YubiKeys store the credential under the same application (ssh:github),
# so ssh-keygen -K derives the SAME filename for either token — recovering
# straight into ~/.ssh can only ever hold one of the two keys. We recover
# into a temp dir and rename by serial instead. Mirrors the SK_KEY inventory
# in .configs/bin/yubikey-audit (can't source it: this preamble runs before
# .configs is cloned) — update both when keys rotate.
# The only file names a GitHub sk stub may have (names reach ssh_config).
SK_STUB_RE='^(github_yub_[A-Za-z0-9_-]+|id_(ed25519|ecdsa)_sk_rk[A-Za-z0-9_-]*)$'
# A private file is a hardware stub only if the KEY says so (not its .pub label).
# -P '' never prompts: an encrypted file just fails.
stub_name_ok() { local LC_ALL=C; [[ "$1" =~ $SK_STUB_RE ]]; }
stub_pub() { SSH_ASKPASS_REQUIRE=never ssh-keygen -y -P '' -f "$1" </dev/null 2>/dev/null; }
is_sk_stub() { [[ "$(stub_pub "$1" | cut -d' ' -f1)" == sk-* ]]; }
declare -A SK_NAME=(
  [37183681]="github_yub_primary"
  [37183574]="github_yub_backup"
)
SK_SERIALS=(37183681 37183574)

# Paths of all resident FIDO2 (-sk) github keys present locally, one per
# line — the preferred github identities. Canonical names first, legacy
# ssh-keygen -K default names next, then any other *.pub carrying an
# sk-ssh-ed25519@openssh.com ... ssh:github key. Returns 1 if none.
gh_resident_keys() {
  local f rc=1 _seen=""
  # primary before backup (glob order would put backup first). Only names a
  # stub can have: they reach ssh_config, so nothing else is ever pinned.
  for f in "$HOME"/.ssh/github_yub_primary "$HOME"/.ssh/github_yub_backup \
           "$HOME"/.ssh/github_yub_* "$HOME"/.ssh/id_*_sk_rk*; do
    stub_name_ok "${f##*/}" || continue
    grep -qxF "$f" <<<"$_seen" 2>/dev/null && continue; _seen+="$f"$'\n'
    [[ -f "$f" && ! -L "$f" ]] && { printf '%s\n' "$f"; rc=0; }
  done
  return $rc
}

# Print expected YubiKey prompts before ssh/git-over-ssh auth to github.com.
sk_auth_prompt_hint() {
  local n_sk; n_sk="$(github_pinned_sk_count)"
  if (( n_sk > 0 )); then
    log "YubiKey: up to $((2*n_sk)) touches and $n_sk PIN (per pinned key ssh tries: 1 touch; a verify-required key adds 1 PIN + 1 more touch)"
  else
    log "YubiKey: 0 touches, 0 PIN (no resident -sk key pinned in github.com stanza)"
  fi
}

# Doctor for both canonical GitHub FIDO2 stubs (no card touched): maps local .pub
# blobs against `gh ssh-key list` authentication rows; reports unverified count if gh unavailable.
audit_github_stubs() {
  local f key title gh_key _created _id key_type _rest s name want_key gh_out gh_rc=1 gh_reason=""
  local -a local_files=()
  local -A local_key=() blob_files=() gh_registered=() gh_serial_key=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local_files+=("$f"); key=""
    [[ -r "$f.pub" ]] && key="$(awk 'NR==1 && $1!="" && $2!="" { print $1 " " $2; exit }' "$f.pub" 2>/dev/null || true)"
    local_key["$f"]="$key"
    [[ -n "$key" ]] && blob_files["$key"]="${blob_files[$key]:+${blob_files[$key]}, }$(basename "$f")"
  done <<<"${GH_SKS:-}"

  if ! command -v gh >/dev/null 2>&1; then gh_reason="gh not installed"
  else gh_out="$(gh ssh-key list 2>/dev/null)"; gh_rc=$?; (( gh_rc == 0 )) || gh_reason="gh not logged in or API unreachable"; fi

  if (( gh_rc == 0 )); then
    while IFS=$'\t' read -r title gh_key _created _id key_type _rest; do
      [[ "$key_type" == authentication && -n "$gh_key" ]] || continue
      gh_key="$(awk '{ if ($1!="" && $2!="") print $1 " " $2 }' <<<"$gh_key")"
      [[ -n "$gh_key" ]] || continue
      gh_registered["$gh_key"]="$title"
      for s in "${SK_SERIALS[@]}"; do [[ "$title" =~ (^|[^0-9])$s([^0-9]|$) ]] && gh_serial_key["$s"]="$gh_key"; done
    done <<<"$gh_out"
    for f in "${local_files[@]}"; do
      key="${local_key[$f]:-}"
      if [[ -z "$key" ]]; then warn "local stub $(basename "$f") has no readable .pub file — cannot verify against GitHub"
      elif [[ -z "${gh_registered[$key]:-}" ]]; then
        warn "local stub $(basename "$f") is not registered on GitHub"
        hint "register it (gh ssh-key add $f.pub) or remove the stale stub"
      fi
    done
    for s in "${SK_SERIALS[@]}"; do
      name="${SK_NAME[$s]}"; want_key="${gh_serial_key[$s]:-}"
      if [[ -z "$want_key" ]]; then
        warn "github stub $name (serial $s): no authentication key with serial $s found in gh ssh-key list — cannot verify by blob"
      elif [[ -n "${blob_files[$want_key]:-}" ]]; then
        ok "github stub $name (serial $s) present locally (${blob_files[$want_key]}) and registered on GitHub"
      else
        warn "github stub $name (serial $s) missing locally"
        hint "plug YubiKey $s and run: profiles/workstation/preamble-github-auth.sh recover"
        hint "or copy stubs from another box: profiles/workstation/preamble-github-auth.sh copy <user@host>"
      fi
    done
  else
    local n_unique="${#blob_files[@]}"
    warn "github stubs: $n_unique distinct local stub pair(s) found — not verified against GitHub ($gh_reason)"
    hint "log in with 'gh auth login' (installing gh if needed) to verify local stubs against GitHub"
    (( n_unique < ${#SK_SERIALS[@]} )) && hint "to add a missing YubiKey stub: profiles/workstation/preamble-github-auth.sh recover  (or: copy <user@host>)"
  fi
}

# Copy github FIDO2 (-sk) stub pairs over ONE announced ssh tar stream into a
# mode-700 temp dir inside ~/.ssh; installs complete pairs via mv -n and pins them.
copy_resident_keys() {
  local host="$COPY_SRC" remote_dir='~/.ssh' cd_expr remote_cmd tmp pub name dst
  local -a ps=(); local added=0 skipped=0 matched=0 incomplete=0
  if [[ "$COPY_SRC" == *:* ]]; then host="${COPY_SRC%%:*}"; remote_dir="${COPY_SRC#*:}"; fi
  remote_dir="${remote_dir%/}"
  if [[ "$remote_dir" == "~" ]]; then cd_expr='cd ~'
  elif [[ "$remote_dir" == "~/"* ]]; then printf -v cd_expr 'cd ~/%q' "${remote_dir#'~/'}"
  else printf -v cd_expr 'cd %q' "$remote_dir"; fi
  remote_cmd="$cd_expr"' && sh -c '\''set --; for p in *.pub; do [ -f "$p" ] || continue; read -r t b a _ < "$p" || [ -n "$t" ] || continue; [ "$t" = "sk-ssh-ed25519@openssh.com" ] && [ -n "$b" ] && [ "$a" = "ssh:github" ] || continue; k="${p%.pub}"; set -- "$@" "$p"; [ -f "$k" ] && set -- "$@" "$k"; done; [ "$#" -gt 0 ] || exit 3; tar cf - -- "$@"'\'''
  tmp="$(mktemp -d "$HOME/.ssh/copy.XXXXXX")"; chmod 700 "$tmp"
  _COPY_TMP="$tmp"; trap 'rm -rf "${_COPY_TMP:-}"' EXIT
  log "copying GitHub FIDO2 stubs from $host (its host key must already be known): 1 ssh connection; YubiKey: 0 PIN, 0 touch if ssh to $host uses a disk key, else up to 2 touches + 1 PIN per YubiKey key it offers..."
  ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -- "$host" "$remote_cmd" \
    | tar -xf - -C "$tmp" --no-same-owner --no-same-permissions
  ps=("${PIPESTATUS[@]}")
  if (( ps[0] == 3 )); then
    rm -rf "$tmp"; _COPY_TMP=""; fail "no sk-ssh-ed25519@openssh.com ssh:github stubs found on $COPY_SRC"; return 1
  elif (( ps[0] != 0 || ps[1] != 0 )); then
    rm -rf "$tmp"; _COPY_TMP=""; fail "ssh/tar transfer failed from $COPY_SRC (ssh=${ps[0]}, tar=${ps[1]})"; return 1
  fi
  for pub in "$tmp"/*.pub; do
    [[ -f "$pub" && ! -L "$pub" ]] || continue
    awk 'NR==1 && $1=="sk-ssh-ed25519@openssh.com" && $2!="" && $3=="ssh:github"{ok=1} END{exit !ok}' "$pub" 2>/dev/null || continue
    name="$(basename "${pub%.pub}")"
    stub_name_ok "$name" || { warn "ignoring ${name@Q} from $COPY_SRC (not a stub file name)"; continue; }
    dst="$HOME/.ssh/$name"
    if [[ ! -f "$tmp/$name" || -L "$tmp/$name" ]]; then
      warn "incomplete transfer for $name (private stub missing from $COPY_SRC) — skipping"; incomplete=1; continue
    fi
    chmod 600 "$tmp/$name"
    if ! is_sk_stub "$tmp/$name" || [[ "$(stub_pub "$tmp/$name" | cut -d' ' -f1,2)" != "$(cut -d' ' -f1,2 "$pub")" ]]; then
      warn "$name from $COPY_SRC is not a hardware (sk) stub matching its .pub — not installed"; continue
    fi
    matched=$((matched + 1))
    if [[ -e "$dst" || -e "$dst.pub" ]]; then
      warn "$name already exists — keeping it (not overwriting)"; skipped=$((skipped + 1)); continue
    fi
    if chmod 600 "$tmp/$name" && chmod 644 "$pub" \
       && mv -n "$tmp/$name" "$dst" && [[ ! -e "$tmp/$name" ]] \
       && mv -n "$pub" "$dst.pub" && [[ ! -e "$pub" ]]; then
      added=$((added + 1))
    else
      warn "could not install stub pair $name into $HOME/.ssh"; incomplete=1
    fi
  done
  rm -rf "$tmp"; _COPY_TMP=""
  (( matched > 0 || incomplete )) || { fail "no valid sk-ssh-ed25519@openssh.com ssh:github stub found on $COPY_SRC"; return 1; }
  GH_SKS="$(gh_resident_keys || true)"
  pin_resident_keys && log "pinned copied resident key(s) in github stanza" || true
  (( ! incomplete )) || { fail "copy incomplete: +$added new, $skipped existing kept"; return 1; }
  ok "copy done: +$added new, $skipped existing kept"
}

# The github.com stanza's lines, IdentityFile values with ~ expanded — so a
# key written as ~/.ssh/x and one written as $HOME/.ssh/x read the same.
github_stanza() {
  awk '/^[[:space:]]*Host[[:space:]]+github\.com([[:space:]]|$)/{g=1; next}
       /^[[:space:]]*Host[[:space:]]/{g=0} g' "$CFG" 2>/dev/null \
    | sed -E "s#^([[:space:]]*IdentityFile[[:space:]]+)~/#\\1$HOME/#"
}
stanza_has_identity() { github_stanza | grep -qE "^[[:space:]]*IdentityFile[[:space:]]+$1[[:space:]]*$"; }

# ssh offers identities in stanza order. A resident key pinned SECOND, behind a
# passphrase file key, means a passphrase prompt before every touch — and a
# stanza that pins a resident key without `IdentityAgent none` lets an agent
# (gnome-keyring) intercept. Presence alone hid both for two months
# (2026-09-13); this reads order and the lock. Warns; never rewrites order.
audit_github_stanza() {
  local f first
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    stanza_has_identity "$f" || warn "github stanza present but resident key $f not pinned"
  done <<<"$GH_SKS"
  first="$(github_stanza | sed -nE 's/^[[:space:]]*IdentityFile[[:space:]]+//p' | head -1)"
  if [[ -n "$first" ]] && ! grep -qxF "$first" <<<"$GH_SKS"; then
    warn "github stanza offers $first before the resident key — ssh tries identities in order (passphrase prompt before every touch); move the resident key first"
  fi
  if ! github_stanza | grep -qE '^[[:space:]]*IdentityAgent[[:space:]]+none[[:space:]]*$'; then
    warn "github stanza pins a resident key but lacks 'IdentityAgent none' — an agent can intercept; add it under IdentitiesOnly yes"
  fi
}

# Idempotently pin every resident key into an existing github stanza.
pin_resident_keys() {
  local f pinned=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    stanza_has_identity "$f" && continue
    # append BELOW the stanza's last IdentityFile (or its Host line), so an
    # already-pinned primary stays first — ssh tries identities in order
    ADD="  IdentityFile $f" awk '
      { L[NR]=$0 }
      /^[[:space:]]*Host[[:space:]]+github\.com([[:space:]]|$)/ { g=1; at=NR; next }
      g && /^[[:space:]]*Host[[:space:]]/ { g=0 }
      g && /^[[:space:]]*IdentityFile[[:space:]]/ { at=NR }
      END { add=ENVIRON["ADD"]; for (i=1;i<=NR;i++) { print L[i]; if (i==at) print add } }' "$CFG" > "$CFG.tmp" \
      && mv "$CFG.tmp" "$CFG" && chmod 600 "$CFG"
    pinned=1
  done < <(gh_resident_keys || true)
  if (( pinned )) && ! grep -qF "IdentitiesOnly yes" "$CFG"; then
    sed -i "/^Host github\.com$/a\\  IdentitiesOnly yes\n  IdentityAgent none" "$CFG"
  fi
  return $(( ! pinned ))
}

# Recover resident keys from the plugged YubiKey (PIN + touch) into a temp
# dir, then rename the github key to its serial's canonical name (see
# SK_NAME) — never overwrites an existing key, so the other YubiKey's stub
# survives when you re-run with the second token. Pins whatever is on disk.
# Returns 0 when a new key landed.
recover_resident_keys() {
  local serial="" name tmp found=0 f dst
  if command -v ykman >/dev/null 2>&1; then
    log "reading YubiKey serial (YubiKey prompts expected: 0 PIN, 0 touch)..."
    serial="$(ykman list --serials 2>/dev/null | head -1 || true)"
  fi
  name="${SK_NAME[${serial:-none}]:-}"
  tmp="$(mktemp -d "$HOME/.ssh/recover.XXXXXX")"
  log "recovering resident ssh keys via ssh-keygen -K (YubiKey prompts expected: 1 PIN; up to 1 touch)..."
  if (cd "$tmp" && ssh-keygen -K); then
    for f in "$tmp"/id_*_sk_rk*; do
      [[ -f "$f" && "$f" != *.pub ]] || continue
      if [[ -n "$name" && "$(basename "$f")" == id_*_sk_rk_github ]]; then
        dst="$HOME/.ssh/$name"
      else
        dst="$HOME/.ssh/$(basename "$f")"
        [[ -z "$name" ]] && warn "serial ${serial:-unknown} not in SK_NAME — keeping default filename"
      fi
      if [[ -e "$dst" ]]; then
        warn "$(basename "$dst") already exists — keeping it (not overwriting)"
      else
        mv "$f" "$dst"; [[ -f "$f.pub" ]] && mv "$f.pub" "$dst.pub"
        chmod 600 "$dst"; found=1
      fi
    done
  else
    warn "ssh-keygen -K failed (keys not resident on this YubiKey?)"
  fi
  rm -rf "$tmp"
  GH_SKS="$(gh_resident_keys || true)"
  pin_resident_keys || true
  return $(( ! found ))
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
(( INSTALL )) && chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true
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
GH_SKS="$(gh_resident_keys || true)"
if ! grep -qE '^[[:space:]]*Host[[:space:]]+github\.com' "$CFG" 2>/dev/null; then
  if (( INSTALL )); then
    { echo
      echo "Host github.com"
      echo "  HostName ssh.github.com"
      echo "  Port 443"
      echo "  PreferredAuthentications publickey"
      echo "  ControlMaster no"
      echo "  ControlPath none"
      if [[ -n "$GH_SKS" ]]; then
        echo "  IdentitiesOnly yes"
        echo "  IdentityAgent none"
        while IFS= read -r f; do echo "  IdentityFile $f"; done <<<"$GH_SKS"
      fi
    } >> "$CFG"
    chmod 600 "$CFG"
    log "wrote github.com stanza${GH_SKS:+ (pinned resident keys)}"
  else
    warn "~/.ssh/config: no github.com stanza"
  fi
else
  ok "ssh config: github.com stanza present"
  # idempotently pin any unpinned resident keys into the existing stanza
  if [[ -n "$GH_SKS" ]]; then
    if (( INSTALL )); then
      pin_resident_keys && log "pinned resident key(s) in existing github stanza"
    fi
    audit_github_stanza
  fi
  # No connection sharing is ever written for github: a master kept open
  # after a tap lets any process push with no touch (Fable 2026-11-27).
  # Removing what older runs wrote is a follow-up; until then, by hand.
fi

# ---- 2b. recover mode (see header)
if (( RECOVER )); then
  recover_resident_keys && log "new key adopted" || ok "no new key (already on disk — kept)"
  audit_github_stubs
  log "testing github auth..."
  sk_auth_prompt_hint
  # ssh -T exits 1 even on a greeting (no shell) and lib.sh sets pipefail, so
  # judge the text, not the status; the "Confirm user presence" prompt still
  # reaches the terminal via tee.
  greet="$(ssh -T git@github.com 2>&1 | tee /dev/stderr || true)"
  if grep -q 'successfully authenticated' <<<"$greet"; then
    ok "github ssh auth works"; exit 0
  fi
  fail "github ssh auth failed — is this key's pubkey registered on GitHub? (ssh-keygen -lf <key>.pub)"
  exit 1
fi

# ---- 2c. copy mode (see header)
if (( COPY )); then
  copy_resident_keys || exit 1
  audit_github_stubs
  exit 0
fi

# ---- 2d. stub doctor (every check and install run, no card touched)
audit_github_stubs

# ---- 3. auth + clone, minimum touches: just TRY the clone — a separate
# "does auth work" probe would cost its own touch.
try_clone() {
  mkdir -p "$(dirname "$DEST")"
  git_resolves_to_github_ssh "$REPO" && sk_auth_prompt_hint
  git clone "$REPO" "$DEST" 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"
  [[ -d "$DEST/.git" ]]
}

if [[ -d "$DEST/.git" ]]; then
  ok ".configs already cloned — no auth needed this run"
  exit 0
fi
if (( ! INSTALL )); then
  warn ".configs not cloned (install will handle auth + clone)"
  exit 0
fi

log "cloning .configs..."
if try_clone; then ok ".configs cloned"; exit 0; fi

# clone failed → recover resident keys from a plugged security key (SSH only)
if git_resolves_to_github_ssh "$REPO" && lsusb 2>/dev/null | grep -qiE 'yubico|fido'; then
  warn "clone failed — recovering resident ssh keys from YubiKey"
  if recover_resident_keys; then
    log "recovered key(s) pinned in ssh config — retrying clone"
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
