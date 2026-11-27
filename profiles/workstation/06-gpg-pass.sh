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
# Opt-in PAT check (touches YubiKey once): VERIFY_ADMIN_PAT=1 streams
# `pass show github/admin-pat` into a verdict-only shape check (no secret in
# shell vars or output). Default (0) uses no-card packet inspection only.
#
# Idempotent: re-run is success. check mode reports state, changes nothing.
SCRIPT_NAME="ws-06-gpg-pass"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

# OpenPGP keys whose private halves live on YubiKeys — ALL of them (primary
# and backup), space-separated. The pass store is encrypted to every listed
# key so whichever YubiKey is plugged can decrypt; one key only means the
# other card reads nothing (2026-09-05: backup key plugged, store to primary).
# Overridable per-host; default is the kit owner's pair.
FPRS="$(conf_get gpg_key_fpr '8733634755706236EF6E1052D9259AC1BF0910D1 7BF67A998A2E7896B0752B37B65E1E766C230F61')"
FPR="${FPRS%% *}"      # first = primary, used where one id is needed
CONFIGS="$HOME/git/.configs"
GNUPG="$HOME/.gnupg"
STORE="${PASSWORD_STORE_DIR:-$HOME/.password-store}"

section "gpg + pass ($MODE)"
# The chain is the kit owner's: his YubiKeys, scdaemon.conf from .configs.
if [[ "$(conf_get configs yes)" == no ]]; then
  ok "configs=no — gpg/pass chain skipped (it needs .configs and the owner's YubiKeys)"
  exit 0
fi
if [[ "$(conf_get configs_role full)" == agent ]]; then
  ok "configs_role=agent — personal GPG/pass chain skipped"
  exit 0
fi

# ---- 0. deps present? (apt manifest installs them; just verify here) --------
for b in gpg pass scdaemon; do
  command -v "$b" >/dev/null 2>&1 \
    || [[ -x "/usr/lib/gnupg/$b" || -x "/usr/libexec/$b" ]] \
    || { warn "$b missing — apt phase should install it (manifests/apt/cli-system.list)"; }
done

# ---- 1. pcscd service (scdaemon goes through it, never raw USB) -------------
if systemctl is-active --quiet pcscd 2>/dev/null; then
  ok "pcscd active"
elif ! pkg_installed pcscd; then
  warn "pcscd not installed — apt phase (cli-system) installs it; enable deferred"
elif (( INSTALL )); then
  do_or_say sudo systemctl enable --now pcscd
else
  warn "pcscd not running (install enables it)"
fi

# ---- 1b. can pcscd (runs as user pcscd) open the key? libccid's udev rule
# ---- sets GROUP=pcscd on CCID devices at ADD time; a key plugged before
# ---- libccid was installed stays root:root and pcscd logs LIBUSB_ERROR_ACCESS
# ---- forever (2026-09-05). Re-add the usb subsystem so the rule applies now.
YK_NODE="$(lsusb 2>/dev/null | awk '/Yubico/{printf "/dev/bus/usb/%s/%s\n", $2, substr($4,1,3); exit}')"
if [[ -n "$YK_NODE" && -e "$YK_NODE" ]]; then
  if [[ "$(stat -c %G "$YK_NODE" 2>/dev/null)" == pcscd ]] || ! id pcscd >/dev/null 2>&1; then
    ok "YubiKey USB node accessible to pcscd"
  elif (( INSTALL )); then
    warn "YubiKey USB node $YK_NODE not group pcscd — re-applying udev rules (key was plugged before libccid)"
    do_or_say sudo udevadm trigger --action=add --subsystem-match=usb
    do_or_say sudo systemctl restart pcscd
    [[ "$(stat -c %G "$YK_NODE" 2>/dev/null)" == pcscd ]] || hint "still not group pcscd — unplug and replug the key"
  else
    warn "YubiKey USB node $YK_NODE not group pcscd — pcscd can't open it (install re-triggers udev)"
  fi
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
card_fetched=0
for FPR in $FPRS; do
if gpg --list-keys "$FPR" >/dev/null 2>&1; then
  ok "public key present (${FPR: -8})"
elif (( INSTALL )); then
  if [[ -f "$CONFIGS/gnupg/pubkey.asc" ]]; then
    do_or_say gpg --import "$CONFIGS/gnupg/pubkey.asc"
  elif (( ${KIT_PASS:-1} == 1 && ! card_fetched )) && lsusb 2>/dev/null | grep -qiE 'yubico|fido'; then
    card_fetched=1
    log "fetching public key URL from card (YubiKey prompts expected: 0 PIN, 0 touch)..."
    if printf 'fetch\nquit\n' | gpg --command-fd 0 --edit-card >/dev/null 2>&1; then
      log "fetched public key via URL on card"
    else
      do_or_say gpg --recv-keys "$FPR" || true
    fi
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
    ok "ownertrust: ultimate (${FPR: -8})"
  elif (( INSTALL )); then
    echo "$FPR:6:" | do_or_say gpg --import-ownertrust
  else
    warn "ownertrust not ultimate (install sets it)"
  fi
fi
done
FPR="${FPRS%% *}"

# ---- 4. card stubs (route sign/decrypt to the YubiKey) ---------------------
# `gpg --card-status` learns the card and writes the secret-key STUBS; without a
# plugged card it just errors — harmless, we only warn. Capped at once per
# bootstrap run (pass 1 only) so missing stubs never loop card operations.
# whichever listed key is on the plugged card is the one that gets stubs
stubs_for() { local f; for f in $FPRS; do gpg -K "$f" 2>/dev/null | grep -q 'ssb>' && { echo "$f"; return 0; }; done; return 1; }
if k="$(stubs_for)"; then
  ok "card stubs present (sign/decrypt → YubiKey, key ${k: -8})"
elif (( INSTALL )); then
  if (( ${KIT_PASS:-1} > 1 )); then
    warn "card stubs still absent (gpg --card-status already ran on pass 1 — skipping to avoid card loop)"
  elif lsusb 2>/dev/null | grep -qiE 'yubico|fido'; then
    log "reading YubiKey OpenPGP card stubs (YubiKey prompts expected: 0 PIN, 0 touch)..."
    card_out="$(gpg --card-status)" || true
    if k="$(stubs_for)"; then ok "card stubs created (key ${k: -8})"
    else
      warn "card stubs not created — the plugged card's key is none of: $FPRS"
      card_sig="$(awk -F': ' '/^Signature key/{gsub(/ /,"",$2); print $2}' <<<"$card_out")"
      hint "card key: ${card_sig:-unknown} — add it to gpg_key_fpr in $HOST_CONF"
    fi
  else
    warn "no YubiKey plugged — skipping card stubs (plug in + re-run)"
  fi
else
  warn "card stubs absent (plug YubiKey + install)"
fi

# ---- 5. pass init + per-entry recipient doctor (no card decrypt) -----------
# Reads actual PKESK recipient keyids from each .gpg file via
# `gpg --list-only --list-packets` and maps them to each listed key's
# encryption subkey(s) from `gpg --list-keys --with-colons`. Checking only
# `.gpg-id` misses entries that were never re-encrypted after adding a backup key.
if [[ -f "$STORE/.gpg-id" ]]; then
  missing_ids=""
  for f in $FPRS; do grep -qi "$f" "$STORE/.gpg-id" || missing_ids+=" ${f: -8}"; done

  declare -A ENC_KIDS=() UNREADABLE=()
  for f in $FPRS; do
    ENC_KIDS["$f"]="$(gpg --list-keys --with-colons "$f" 2>/dev/null \
      | awk -F: '($1=="pub" || $1=="sub") && $2!="r" && $2!="d" && $12 ~ /e/ { print toupper($5) }')"
    UNREADABLE["$f"]=0
  done

  total_entries=0
  while IFS= read -r -d '' entry; do
    total_entries=$((total_entries + 1))
    pkts="$(gpg --batch --list-only --list-packets "$entry" 2>/dev/null || true)"
    entry_kids="$(awk '/:pubkey enc packet:/ {
      for (i=1; i<=NF; i++) if ($i == "keyid") { k=$(i+1); sub(/,$/, "", k); print toupper(k) }
    }' <<<"$pkts")"
    for f in $FPRS; do
      [[ -n "${ENC_KIDS[$f]}" ]] || continue
      can_read=0
      while IFS= read -r ek; do
        [[ -n "$ek" ]] || continue
        if grep -qxF "$ek" <<<"$entry_kids" 2>/dev/null; then can_read=1; break; fi
      done <<<"${ENC_KIDS[$f]}"
      (( can_read )) || UNREADABLE["$f"]=$(( UNREADABLE["$f"] + 1 ))
    done
  done < <(find "$STORE" -path "$STORE/.git" -prune -o -type f -name '*.gpg' -print0 2>/dev/null)

  any_gap=0
  if [[ -n "$missing_ids" ]]; then
    warn "pass store .gpg-id missing:$missing_ids — future entries won't encrypt to that YubiKey"
    any_gap=1
  fi
  if (( total_entries > 0 )); then
    for f in $FPRS; do
      if [[ -z "${ENC_KIDS[$f]}" ]]; then
        warn "pass store: public key ${f: -8} not in keyring (or no encryption subkey) — cannot verify $total_entries entry(ies)"
        any_gap=1
      elif (( UNREADABLE["$f"] > 0 )); then
        warn "pass store: key ${f: -8} cannot read ${UNREADABLE[$f]} of $total_entries entry(ies)"
        any_gap=1
      fi
    done
  fi
  if (( ! any_gap )); then
    ok "pass store: all $total_entries entry(ies) encrypted to every listed key"
  else
    hint "re-init to all keys (re-encrypts; needs a card that can decrypt the current entries): pass init $FPRS"
    hint "if no plugged card can decrypt them: pass rm <entry>, pass init $FPRS, pass insert <entry>"
  fi
elif ! command -v pass >/dev/null 2>&1; then
  warn "pass not installed — apt phase (cli-system) installs it; pass init deferred"
elif gpg --list-keys "$FPR" >/dev/null 2>&1 && (( INSTALL )); then
  # shellcheck disable=SC2086
  do_or_say pass init $FPRS
elif (( INSTALL )); then
  fail "cannot pass-init without the public key"
else
  warn "pass store not initialized (install runs: pass init $FPRS)"
fi

# ---- 6. secret entries: report only, never provision -----------------------
# The kit installs no secrets. Surface the gh-admin entry so a fresh box knows
# the one remaining manual step. No-card packet-length check catches stub/short
# non-tokens without touching the YubiKey; opt-in VERIFY_ADMIN_PAT=1 decrypts
# once into memory to verify the prefix without printing the value.
PAT_HINT="pass insert github/admin-pat   # paste a GitHub PAT (classic) w/ scope: repo,read:org,project,workflow"
if [[ -f "$STORE/.gpg-id" ]]; then
  if [[ -f "$STORE/github/admin-pat.gpg" ]]; then
    pat_pkts="$(gpg --batch --list-only --list-packets "$STORE/github/admin-pat.gpg" 2>/dev/null || true)"
    # SEIPD v1 (tag=18 with numeric plen and mdc_method):
    # plen - 1 (version) - 18 (prefix) - 22 (MDC) - 8 (literal header) - 1 (trailing LF)
    # ≈ single-line plaintext chars (plausibility check; multi-line entries measure the whole file).
    pat_plen="$(awk '
      /(^|[[:space:]])tag=18([[:space:]]|$)/ {
        in18=1; plen=""
        for (i=1; i<=NF; i++) if ($i ~ /^plen=[0-9]+$/) { plen=substr($i, 6) }
        next
      }
      /^# off=/ { in18=0 }
      in18 && /mdc_method:/ && plen != "" { print plen; exit }
    ' <<<"$pat_pkts")"
    if [[ -n "$pat_plen" ]]; then
      pat_est=$(( pat_plen - 1 - 18 - 22 - 8 - 1 ))
      if (( pat_est < 40 )); then
        warn "pass entry github/admin-pat looks too short to be a GitHub token (estimated ${pat_est} bytes excl. newline; classic ghp_ is 40 chars, fine-grained github_pat_ is 93)"
        hint "$PAT_HINT"
      else
        ok "pass entry github/admin-pat present (estimated ${pat_est} bytes excl. newline, plausible single-line PAT length)"
      fi
    else
      warn "pass entry github/admin-pat present — length not judged (unknown or unsupported encrypted packet format)"
    fi

    if [[ "${VERIFY_ADMIN_PAT:-0}" == 1 ]]; then
      if (( ${KIT_PASS:-1} > 1 )); then
        warn "github/admin-pat prefix check skipped on pass $KIT_PASS (no card loop)"
      else
        log "verifying github/admin-pat prefix (YubiKey prompts expected: up to 1 PIN, 1 touch — 0 PIN if cached)..."
        pat_verdict=""
        if pat_verdict="$(pass show github/admin-pat | LC_ALL=C awk '
          NR == 1 {
            sub(/\r$/, "")
            if (length($0) == 40 && $0 ~ /^ghp_[A-Za-z0-9]+$/) v = "classic"
            else if (length($0) == 93 && $0 ~ /^github_pat_[A-Za-z0-9_]+$/) v = "fine-grained"
            else v = "invalid"
          }
          END { print (v ? v : "invalid") }
        ')"; then
          case "$pat_verdict" in
            classic)      ok "pass entry github/admin-pat: valid classic PAT (ghp_)" ;;
            fine-grained) ok "pass entry github/admin-pat: valid fine-grained PAT (github_pat_)" ;;
            *)
              warn "pass entry github/admin-pat: decrypted value does not match expected GitHub PAT shape (ghp_ + 36 alnum, or github_pat_ + 82 chars)"
              hint "$PAT_HINT" ;;
          esac
        else
          warn "pass entry github/admin-pat: decrypt failed (is the right YubiKey plugged?)"
        fi
        unset pat_verdict
      fi
    fi
  else
    warn "pass entry github/admin-pat missing (gh-admin needs it)"
    hint "$PAT_HINT"
  fi
fi
