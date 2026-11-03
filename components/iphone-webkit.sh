#!/bin/bash
# component_iphone_webkit: ready .configs' `iphone` check (the refusing-WebKit
# instrument: pinned Playwright + isolated WebKit in ~/.cache/iphone-webkit).
# `iphone` owns its pins and its setup; the kit only asks it: `--check`
# (read-only), and `--setup` when that fails, in install mode. Sourced by 08.
section "iphone WebKit check ($MODE) — .configs bin/iphone"
IPHONE="$HOME/bin/iphone"
if [[ ! -x "$IPHONE" ]]; then
  warn "iphone missing at ~/bin/iphone (the .configs agent role links it); WebKit check not readied"
else
  # Fresh worker phases don't inherit nvm's PATH; iphone runs on node.
  IPHONE_PATH="$PATH"
  if ! command -v node >/dev/null 2>&1 && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    node_bin=$(export NVM_DIR="$HOME/.nvm"; source "$HOME/.nvm/nvm.sh" --no-use; nvm which default 2>/dev/null) || node_bin=''
    [[ -n "$node_bin" ]] && IPHONE_PATH="$(dirname "$node_bin"):$PATH"
  fi
  if PATH="$IPHONE_PATH" "$IPHONE" --check >/dev/null 2>&1; then
    ok "iphone WebKit check ready"
  else
    warn "iphone WebKit check not ready"
    # A counted action (do_or_say), so bootstrap runs another pass after it.
    iphone_setup() { PATH="$IPHONE_PATH" "$IPHONE" --setup; }
    if do_or_say iphone_setup && (( INSTALL )); then
      if PATH="$IPHONE_PATH" "$IPHONE" --check >/dev/null 2>&1; then ok "iphone WebKit check ready (iphone --setup)"
      else miss "iphone: --setup did not make --check pass (run ~/bin/iphone --setup and read its error)"; fi
    elif (( INSTALL )); then
      miss "iphone: --setup failed (run ~/bin/iphone --setup and read its error)"
    fi
  fi
fi
