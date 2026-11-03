#!/bin/bash
# Login shells get the headless PATH (bun, flutter, java, Android tools) from
# ~/.config/setup-kit/headless-env.sh. ~/.ssh/environment can't carry PATH on
# Ubuntu: pam_env resets it after sshd reads the user file. Sourced by
# flutter-headless.sh, which owns the env file. Never writes through a link.
# Also nvm's default node: nvm only reaches PATH where nvm.sh is sourced
# (the interactive part of .bashrc), so login shells and their children lacked it.
PROFILE_LINE='[ ! -r "$HOME/.config/setup-kit/headless-env.sh" ] || . "$HOME/.config/setup-kit/headless-env.sh"; [ ! -s "$HOME/.nvm/nvm.sh" ] || . "$HOME/.nvm/nvm.sh"  # setup-kit'
if [[ -L "$HOME/.profile" ]]; then
  warn "~/.profile is linked ($(readlink "$HOME/.profile")); add the headless environment source there: $PROFILE_LINE"
elif grep -qxF "$PROFILE_LINE" "$HOME/.profile" 2>/dev/null; then
  ok "login shells source the headless environment"
else
  warn "~/.profile does not source the headless environment (login shells miss bun/node/flutter/java)"
  # Append, keeping the existing body and mode; the body is never logged.
  headless_profile_write() { tool_write "$(cat "$HOME/.profile" 2>/dev/null || true)"$'\n'"$PROFILE_LINE" "$HOME/.profile"; }
  do_or_say headless_profile_write || miss "login PATH: ~/.profile not updated; add: $PROFILE_LINE"
fi
