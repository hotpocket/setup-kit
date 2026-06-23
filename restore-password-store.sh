#!/usr/bin/env bash
# Restore the `pass` store from a known host via scp — run ON THE NEW BOX.
#
# The store (~/.password-store) holds the gh-admin PAT (github/admin-pat) and
# the docker creds. Every file is encrypted AT REST to the YubiKey OpenPGP key
# (only the YubiKey + a touch can open it), so the bytes are safe to scp and
# never go anywhere near a git repo. The private keys stay on the YubiKey; the
# only thing that has to travel to a new machine is these encrypted .gpg files.
#
# Usage (on the new box, YubiKey not required for the copy itself):
#   ./restore-password-store.sh brandon@LinuxBeast:~/.password-store
#   SRC=brandon@LinuxBeast:~/.password-store ./restore-password-store.sh
#   FORCE=1 ./restore-password-store.sh user@host:~/.password-store  # overwrite
#
# After it lands, bind the card and test:
#   gpg --card-status                 # plug in a YubiKey -> creates the stub
#   gh-admin api user --jq .login     # PIN + touch; prints your login
#
# Idempotent + SURGICAL: merges missing entries into an existing store instead
# of refusing — you should never have to wipe your whole store to pull one key.
# Entries already present are left untouched (they may be the newer copy);
# FORCE=1 overwrites them. Both sides stay encrypted to the YubiKey, so merging
# files encrypted to different gpg-ids is harmless (pass keys off per-subdir
# .gpg-id, not the store root).
set -euo pipefail

SRC="${1:-${SRC:-}}"
DEST="$HOME/.password-store"
FORCE="${FORCE:-}"

[[ -n "$SRC" ]] || {
  echo "usage: $0 user@known-host:~/.password-store" >&2
  exit 2
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "scp $SRC -> $DEST ..."
# accept-new (not a TOFU prompt that could hang) + a short timeout so an
# unreachable host fails fast. ssh auth to the source must already work.
scp -rp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SRC" "$tmp/store"
[[ -f "$tmp/store/.gpg-id" ]] || {
  echo "no .gpg-id under $SRC — is that the store ROOT (~/.password-store)?" >&2
  exit 1
}

mkdir -p "$DEST"
added=0 skipped=0 overwrote=0
# Merge every file (incl. .gpg-id and nested dirs) relative to the store root.
while IFS= read -r -d '' f; do
  rel="${f#"$tmp/store/"}"
  dst="$DEST/$rel"
  if [[ -e "$dst" ]]; then
    if [[ -z "$FORCE" ]]; then
      echo "  skip (exists): $rel"
      skipped=$((skipped + 1))
      continue
    fi
    overwrote=$((overwrote + 1))
  else
    added=$((added + 1))
  fi
  mkdir -p "$(dirname "$dst")"
  cp -p "$f" "$dst"
done < <(find "$tmp/store" -type f -print0)

chmod -R go-rwx "$DEST"
echo "merge done: +$added new, ~$overwrote overwritten, $skipped left as-is  ($DEST)"
[[ "$skipped" -gt 0 && -z "$FORCE" ]] && echo "  (re-run with FORCE=1 to overwrite the skipped ones)"
echo "next: gpg --card-status   (YubiKey in)   then   gh-admin api user --jq .login"
