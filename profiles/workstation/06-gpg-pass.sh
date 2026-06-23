#!/bin/bash
# GPG-on-YubiKey → pass provisioning. Stands up the chain `gh-admin` (and any
# other `pass`-backed secret) depends on, which NOTHING else in the kit covered
# (the github-auth preamble handles FIDO2/*ssh* keys only; OpenPGP is separate):
#
#   pass show <entry>  →  gpg --decrypt  →  scdaemon → pcscd → YubiKey OpenPGP
#
# The private key was generated ON the card and never leaves it; this phase only
# makes the host able to USE the card: install path (scdaemon/pcscd come from the
# apt manifest), the pcsc-shared scdaemon.conf, the PUBLIC key + ownertrust, the
# card stubs, and `pass init`. Runs after 06 so .configs (which owns scdaemon.conf
# and, ideally, pubkey.asc) is already cloned.
#
# Secret ENTRIES are never provisioned here — `pass insert` stays a manual,
# terminal-only step (no secret belongs in a repo). The phase reports the
# missing entry with the exact command instead.
#
# Idempotent: re-run is success. check mode reports state, changes nothing.
SCRIPT_NAME="ws-06-gpg-pass"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

# OpenPGP key whose private half lives on the YubiKey. Overridable per-host;
# default is the kit owner's key.
FPR="$(conf_get gpg_key_fpr '8733634755706236EF6E1052D9259AC1BF0910D1')"
CONFIGS="$HOME/git/.configs"
GNUPG="$HOME/.gnupg"
STORE="${PASSWORD_STORE_DIR:-$HOME/.password-store}"

section "gpg + pass ($MODE)"

# ---- 0. deps present? (apt manifest installs them; just verify here) --------
for b in gpg pass scdaemon; do
  command -v "$b" >/dev/null 2>&1 || command -v "$b" >/dev/null 2>&1 \
    || [[ -x "/usr/lib/gnupg/$b" || -x "/usr/libexec/$b" ]] \
    || { warn "$b missing — apt phase should install it (manifests/apt/cli-system.list)"; }
done

# ---- 1. pcscd service (scdaemon goes through it, never raw USB) -------------
if systemctl is-active --quiet pcscd 2>/dev/null; then
  ok "pcscd active"
elif (( INSTALL )); then
  do_or_say sudo systemctl enable --now pcscd
else
  warn "pcscd not running (install enables it)"
fi

# ---- 2. scdaemon.conf — owned by .configs, linked into ~/.gnupg ------------
# Mirrors 06-configs' link-or-heal: a divergent REAL file is backed up loudly
# (it may be newer), an identical one is replaced by the link.
mkdir -p "$GNUPG"; chmod 700 "$GNUPG"
SRC="$CONFIGS/gnupg/scdaemon.conf"; TGT="$GNUPG/scdaemon.conf"
if [[ ! -e "$SRC" ]]; then
  warn ".configs/gnupg/scdaemon.conf absent — can't link card config"
  hint "add it to .configs (pcsc-shared + disable-ccid + card-timeout)"
elif [[ -L "$TGT" && "$(readlink -f "$TGT")" == "$(readlink -f "$SRC")" ]]; then
  ok "scdaemon.conf linked to .configs"
elif (( INSTALL )); then
  if [[ -e "$TGT" && ! -L "$TGT" ]]; then
    cmp -s "$SRC" "$TGT" && rm -f "$TGT" \
      || { mv "$TGT" "$TGT.pre-setup-kit"; warn "DIVERGENT scdaemon.conf → backed up .pre-setup-kit (review)"; }
  fi
  ln -sf "$SRC" "$TGT" && { log "linked scdaemon.conf → .configs"; do_or_say gpgconf --kill scdaemon gpg-agent; }
else
  warn "scdaemon.conf not linked to .configs"
fi

# ---- 3. public key + ultimate ownertrust -----------------------------------
# Private key is card-resident; we only need the PUBLIC key on the host so gpg
# can address it. Deterministic source first (pubkey.asc committed to .configs —
# a public key is safe to commit), then the URL on the card, then a keyserver.
if gpg --list-keys "$FPR" >/dev/null 2>&1; then
  ok "public key present (${FPR: -8})"
elif (( INSTALL )); then
  if [[ -f "$CONFIGS/gnupg/pubkey.asc" ]]; then
    do_or_say gpg --import "$CONFIGS/gnupg/pubkey.asc"
  elif lsusb 2>/dev/null | grep -qiE 'yubico|fido' && printf 'fetch\nquit\n' | gpg --command-fd 0 --edit-card >/dev/null 2>&1; then
    log "fetched public key via URL on card"
  else
    do_or_say gpg --recv-keys "$FPR" || true
  fi
  gpg --list-keys "$FPR" >/dev/null 2>&1 \
    && ok "public key imported" \
    || { fail "public key for $FPR not obtained"; hint "commit your public key to .configs/gnupg/pubkey.asc, then re-run"; miss "gpg: pubkey $FPR"; }
else
  warn "public key for $FPR not imported (install will fetch)"
fi

# ultimate ownertrust (no touch; safe to assert every run once the key is present)
if gpg --list-keys "$FPR" >/dev/null 2>&1; then
  if gpg --export-ownertrust 2>/dev/null | grep -q "^$FPR:6:"; then
    ok "ownertrust: ultimate"
  elif (( INSTALL )); then
    echo "$FPR:6:" | do_or_say gpg --import-ownertrust
  else
    warn "ownertrust not ultimate (install sets it)"
  fi
fi

# ---- 4. card stubs (route sign/decrypt to the YubiKey) ---------------------
# `gpg --card-status` learns the card and writes the secret-key STUBS; without a
# plugged card it just errors — harmless, we only warn.
if gpg -K "$FPR" 2>/dev/null | grep -q 'ssb>'; then
  ok "card stubs present (sign/decrypt → YubiKey)"
elif (( INSTALL )); then
  if lsusb 2>/dev/null | grep -qiE 'yubico|fido'; then
    do_or_say gpg --card-status >/dev/null
    gpg -K "$FPR" 2>/dev/null | grep -q 'ssb>' && ok "card stubs created" \
      || warn "card stubs not created (PIN/touch needed, or key mismatch)"
  else
    warn "no YubiKey plugged — skipping card stubs (plug in + re-run)"
  fi
else
  warn "card stubs absent (plug YubiKey + install)"
fi

# ---- 5. pass init ----------------------------------------------------------
if [[ -f "$STORE/.gpg-id" ]]; then
  ok "pass store initialized ($(cat "$STORE/.gpg-id" 2>/dev/null | tr -d '\n' | tail -c 8))"
elif gpg --list-keys "$FPR" >/dev/null 2>&1 && (( INSTALL )); then
  do_or_say pass init "$FPR"
elif (( INSTALL )); then
  fail "cannot pass-init without the public key"
else
  warn "pass store not initialized (install runs: pass init $FPR)"
fi

# ---- 6. secret entries: report only, never provision -----------------------
# The kit installs no secrets. Surface the gh-admin entry so a fresh box knows
# the one remaining manual step.
if [[ -f "$STORE/.gpg-id" ]]; then
  if [[ -f "$STORE/github/admin-pat.gpg" ]]; then
    ok "pass entry github/admin-pat present"
  else
    warn "pass entry github/admin-pat missing (gh-admin needs it)"
    hint "pass insert github/admin-pat   # paste a GitHub PAT (classic) w/ scope: repo,read:org,project"
  fi
fi
