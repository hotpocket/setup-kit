#!/bin/bash
# Capture language toolchain state: pyenv, rustup, nvm, cargo, npm globals,
# pipx, uv, gems, dart pub-cache, go, bun. Tools that survived: bun, .gradle,
# .m2 are partially captured (they're really build caches that re-populate).

SCRIPT_NAME="capture-03-languages"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/languages"
mkdir -p "$OUT"

# --- pyenv ---
if [[ -d "$HOME/.pyenv" ]]; then
  log "Capturing pyenv state..."
  if command -v pyenv >/dev/null 2>&1 || [[ -x "$HOME/.pyenv/bin/pyenv" ]]; then
    export PATH="$HOME/.pyenv/bin:$PATH"
    pyenv versions --bare > "$OUT/pyenv-versions.txt" 2>/dev/null || true
    pyenv global > "$OUT/pyenv-global.txt" 2>/dev/null || true
    log "pyenv versions: $(wc -l < "$OUT/pyenv-versions.txt")"

    # For each pyenv version, capture pip freeze.
    mkdir -p "$OUT/pyenv-pip-freeze"
    while IFS= read -r ver; do
      [[ -z "$ver" ]] && continue
      py="$HOME/.pyenv/versions/$ver/bin/pip"
      if [[ -x "$py" ]]; then
        # Versions like "3.10.16/envs/tts" contain / — flatten for filename.
        safe="${ver//\//__}"
        "$py" freeze > "$OUT/pyenv-pip-freeze/$safe.txt" 2>/dev/null || true
      fi
    done < "$OUT/pyenv-versions.txt"
  fi
fi

# --- pipx ---
if command -v pipx >/dev/null 2>&1; then
  log "Capturing pipx state..."
  pipx list --short > "$OUT/pipx-list.txt" 2>/dev/null || true
fi

# --- uv ---
if command -v uv >/dev/null 2>&1; then
  log "Capturing uv state..."
  uv tool list > "$OUT/uv-tools.txt" 2>/dev/null || true
fi

# --- rustup ---
if command -v rustup >/dev/null 2>&1; then
  log "Capturing rustup state..."
  rustup show > "$OUT/rustup-show.txt" 2>/dev/null || true
  rustup toolchain list > "$OUT/rustup-toolchains.txt" 2>/dev/null || true
  rustup component list --installed > "$OUT/rustup-components.txt" 2>/dev/null || true
fi

# --- cargo installed binaries ---
if command -v cargo >/dev/null 2>&1; then
  log "Capturing cargo state..."
  cargo install --list > "$OUT/cargo-installed.txt" 2>/dev/null || true
fi

# --- nvm + node ---
if [[ -d "$HOME/.nvm" ]]; then
  log "Capturing nvm state..."
  # nvm is a shell function — must source it.
  bash -c 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; nvm ls' \
    > "$OUT/nvm-ls.txt" 2>/dev/null || true
  bash -c 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; nvm version-remote' \
    > "$OUT/nvm-default.txt" 2>/dev/null || true
fi

# --- npm globals ---
if command -v npm >/dev/null 2>&1; then
  log "Capturing npm globals..."
  npm ls -g --depth=0 --json > "$OUT/npm-global.json" 2>/dev/null || true
fi

# --- bun ---
if command -v bun >/dev/null 2>&1; then
  log "Capturing bun state..."
  bun pm ls -g > "$OUT/bun-global.txt" 2>/dev/null || true
fi

# --- go ---
if command -v go >/dev/null 2>&1; then
  log "Capturing go state..."
  go version > "$OUT/go-version.txt"
  # List binaries installed via `go install` (in $GOBIN or $GOPATH/bin).
  ls "${GOBIN:-$HOME/go/bin}" 2>/dev/null > "$OUT/go-bin-list.txt" || true
fi

# --- gem (Ruby) ---
if command -v gem >/dev/null 2>&1; then
  log "Capturing gem state..."
  gem list --local > "$OUT/gem-list.txt" 2>/dev/null || true
fi

# --- dart pub-cache ---
if command -v dart >/dev/null 2>&1 || [[ -d "$HOME/.pub-cache" ]]; then
  log "Capturing dart state..."
  dart --version > "$OUT/dart-version.txt" 2>&1 || true
  # Globally activated dart packages:
  ls "$HOME/.pub-cache/bin" 2>/dev/null > "$OUT/dart-globals.txt" || true
fi

# --- Manually installed binaries (the curl|bash + AppImage corner) ---
log "Inventorying user-installed binaries..."
{
  echo "=== ~/.local/bin ==="
  ls "$HOME/.local/bin" 2>/dev/null
  echo
  echo "=== /usr/local/bin (non-package-managed) ==="
  for f in /usr/local/bin/*; do
    [[ -e "$f" ]] || continue
    if ! dpkg -S "$f" >/dev/null 2>&1; then
      echo "$f"
    fi
  done
  echo
  echo "=== /opt ==="
  ls /opt 2>/dev/null
  echo
  echo "=== AppImages in ~/ ==="
  find "$HOME" -maxdepth 3 -iname "*.AppImage" 2>/dev/null
} > "$OUT/binaries-inventory.txt"

log "Done. Artifacts in $OUT"
