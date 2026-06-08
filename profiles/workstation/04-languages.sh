#!/bin/bash
# Language toolchains from manifests/lang/: pyenv (interpreters only),
# pipx tools, nvm + LTS + npm globals. Optional stacks (go, rust) per conf.
SCRIPT_NAME="ws-04-languages"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

LANG_M="$MANIFEST_DIR/lang"

# ---------------------------------------------------------------- python
if [[ "$(conf_get lang_python yes)" == yes ]]; then
  section "python ($MODE)"
  if [[ -d "$HOME/.pyenv" ]]; then
    ok "pyenv present"
  else
    warn "pyenv missing"
    do_or_say bash -c 'curl -fsSL https://pyenv.run | bash'
  fi
  if [[ -d "$HOME/.pyenv" ]]; then
    export PYENV_ROOT="$HOME/.pyenv" PATH="$HOME/.pyenv/bin:$PATH"
    eval "$(pyenv init - 2>/dev/null)" || true
    while IFS= read -r ver; do
      [[ "$ver" == pipx:* ]] && continue
      # prefix match: manifest says "3.12", installed is "3.12.11".
      # no grep -q here: with pipefail, -q's early exit SIGPIPEs the writer
      if pyenv versions --bare 2>/dev/null | grep -E "^${ver}(\.|$)" >/dev/null; then
        ok "python $ver"
      else
        warn "python $ver not built"
        # build deps come from apt dev-python group — checked here
        if (( INSTALL )); then
          for dep in libssl-dev libbz2-dev libreadline-dev liblzma-dev; do
            dpkg -s "$dep" >/dev/null 2>&1 \
              || { fail "pyenv build dep $dep missing — run 02-apt-install first"; continue 2; }
          done
          pyenv install "$ver" 2>&1 | tee -a "$LOG_DIR/pyenv.log" || miss "pyenv: $ver"
        else
          hint "pyenv install $ver"
        fi
      fi
    done < <(manifest_pkgs "$LANG_M/python.list")
  fi
  # global stays SYSTEM by policy (2026-06-07). Pinning global to 3.12 made
  # the pyenv-version prompt fire in EVERY dir, defeating its purpose (it's
  # meant to flag projects that diverge from system via a .python-version).
  # system python3 ships via apt; 3.12 is installed above as an *available*
  # version for projects; tools needing it use explicit interpreters/venvs
  # (e.g. the `tts` virtualenv), never the global.
  if command -v pyenv >/dev/null 2>&1; then
    CUR_GLOBAL="$(pyenv global 2>/dev/null | head -1)"
    if [[ "$CUR_GLOBAL" == system ]]; then
      ok "pyenv global = system (clean prompt; projects opt in via .python-version)"
    else
      warn "pyenv global is '$CUR_GLOBAL' — policy is system (keeps the prompt quiet)"
      do_or_say pyenv global system
    fi
  fi

  # pipx tools (pipx itself comes from apt dev-python group)
  while IFS= read -r entry; do
    [[ "$entry" == pipx:* ]] || continue
    tool="${entry#pipx:}"
    if command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep "^$tool " >/dev/null; then
      ok "pipx $tool"
    else
      warn "pipx $tool missing"
      do_or_say pipx install "$tool" || miss "pipx: $tool"
    fi
  done < <(manifest_pkgs "$LANG_M/python.list")
fi

# ---------------------------------------------------------------- node
if [[ "$(conf_get lang_node yes)" == yes ]]; then
  section "node ($MODE)"
  export NVM_DIR="$HOME/.nvm"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    ok "nvm present"
  else
    warn "nvm missing"
    do_or_say bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash'
  fi
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh"
    want="$(manifest_pkgs "$LANG_M/node.list" | grep '^nvm:' | head -1)"
    want="${want#nvm:}"
    if nvm ls "${want:-lts/*}" >/dev/null 2>&1; then
      ok "node ${want} installed"
    else
      warn "node ${want} not installed"
      do_or_say nvm install "${want:-lts/*}" --default || miss "nvm: $want"
    fi
    while IFS= read -r entry; do
      [[ "$entry" == npm:* ]] || continue
      pkg="${entry#npm:}"
      if command -v npm >/dev/null 2>&1 && npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
        ok "npm -g $pkg"
      else
        warn "npm -g $pkg missing"
        do_or_say npm install -g "$pkg" || miss "npm-g: $pkg"
      fi
    done < <(manifest_pkgs "$LANG_M/node.list")
  fi
fi

# ---------------------------------------------------------------- optional: go
if [[ "$(conf_get group_dev_go no)" == yes ]]; then
  section "go ($MODE) — optional stack"
  if command -v go >/dev/null 2>&1; then
    ok "go $(go version 2>/dev/null | awk '{print $3}')"
  else
    warn "go missing"
    do_or_say sudo apt-get install -y golang-go
  fi
  if command -v go >/dev/null 2>&1; then
    for tool in golang.org/x/tools/gopls@latest honnef.co/go/tools/cmd/staticcheck@latest; do
      bin="$(basename "${tool%@*}")"
      if [[ -x "$HOME/go/bin/$bin" ]]; then
        ok "go tool $bin"
      else
        warn "go tool $bin missing"
        do_or_say go install "$tool" || miss "go install: $tool"
      fi
    done
  fi
fi

# ---------------------------------------------------------------- optional: rust
if [[ "$(conf_get group_dev_rust no)" == yes ]]; then
  section "rust ($MODE) — optional stack (rustup, NOT apt)"
  if command -v rustup >/dev/null 2>&1; then
    ok "rustup present"
  else
    warn "rustup missing"
    do_or_say bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable"
  fi
fi
