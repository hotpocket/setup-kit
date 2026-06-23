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
#
# After it lands, bind the card and test:
#   gpg --card-status                 # plug in a YubiKey -> creates the stub
#   gh-admin api user --jq .login     # PIN + touch; prints your login
#
# Idempotent: refuses to clobber a NON-EMPTY store (it may be the newer copy).
set -euo pipefail

SRC="${1:-${SRC:-}}"
DEST="$HOME/.password-store"

[[ -n "$SRC" ]] || {
  echo "usage: $0 user@known-host:~/.password-store" >&2
  exit 2
}

# Refuse to overwrite a store that already has entries.
if compgen -G "$DEST/**/*.gpg" >/dev/null 2>&1 || ls "$DEST"/*.gpg >/dev/null 2>&1; then
  echo "refusing: $DEST already has entries ($(find "$DEST" -name '*.gpg' | wc -l))." >&2
  echo "move it aside first if you really want to re-pull." >&2
  exit 0
fi
# An empty/half store dir would make scp nest the copy inside it — clear it.
[[ -d "$DEST" ]] && rmdir "$DEST" 2>/dev/null || true
[[ -e "$DEST" ]] && { echo "refusing: $DEST exists and is not an empty dir." >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "scp $SRC -> $DEST ..."
# accept-new (not a TOFU prompt that could hang) + a short timeout so an
# unreachable host fails fast. ssh auth to the source must already work.
scp -rp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SRC" "$tmp/store"
[[ -f "$tmp/store/.gpg-id" ]] || {
  echo "no .gpg-id under $SRC — is that the store ROOT (~/.password-store)?" >&2
  exit 1
}
mv "$tmp/store" "$DEST"
chmod -R go-rwx "$DEST"
echo "restored $(find "$DEST" -name '*.gpg' | wc -l) entries to $DEST"
echo "next: gpg --card-status   (YubiKey in)   then   gh-admin api user --jq .login"
