#!/bin/bash
# Components: oom-zram/uutils-ls/aws-cli (default ON), docker, herdr/ollama/t3code/codex/whisper/lid-ignore (opt-in), dictation/ocr/tts.
# Specs live in components/*.md — keep behavior in sync with them.
SCRIPT_NAME="ws-07-components"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

# Opt-in headless tools: existing hosts retain their previous path.
for tool in uv blender flutter_headless; do
  if [[ "$(conf_get "component_$tool" no)" == yes ]]; then
    source "$KIT_DIR/components/${tool//_/-}.sh"
  fi
done

# Memory guards use a prefixed filesystem only in calibration tests.
source "$KIT_DIR/components/tmp-on-disk.sh"
if [[ "$(conf_get component_oom_zram yes)" == yes ]]; then
  source "$KIT_DIR/components/oom-zram.sh"
fi

source "$KIT_DIR/components/resource-guards.sh"

# ------------------------------------------------------------- docker-rootless
# Rootless docker: rootful daemon disabled, user-level dockerd; .bashrc
# exports DOCKER_HOST to the user socket. Without this, the kit's docker-ce
# install + .configs' DOCKER_HOST export point the CLI at a missing socket.
DOCKER_MODE="$(conf_get component_docker_rootless yes)"
if [[ "$DOCKER_MODE" == no ]] && command -v docker >/dev/null 2>&1; then
  # explicit ROOTFUL mode (service VMs): daemon enabled, user in docker
  # group. The .bashrc DOCKER_HOST guard keeps the CLI on the rootful socket.
  section "docker-rootful ($MODE)"
  if systemctl is-active docker >/dev/null 2>&1; then
    ok "rootful docker active"
  else
    warn "rootful docker not running"
    do_or_say sudo systemctl enable --now docker
  fi
  if id -nG "$USER" | grep -qw docker; then
    ok "user in docker group"
  else
    warn "user not in docker group"
    do_or_say sudo usermod -aG docker "$USER"
  fi
elif [[ "$DOCKER_MODE" == yes ]] && command -v docker >/dev/null 2>&1; then
  section "docker-rootless ($MODE)"
  if docker info 2>/dev/null | grep -qi rootless; then
    ok "docker is rootless"
  else
    if ! dpkg-query -W -f='${Status}' docker-ce-rootless-extras 2>/dev/null | grep -q "ok installed"; then
      warn "docker-ce-rootless-extras not installed (02-apt-install provides it)"
    else
      warn "docker running rootful (or not configured) — converting to rootless"
      if (( INSTALL )); then
        sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true
        # a stale rootful socket file makes setuptool abort even with the
        # daemon stopped — clear it before converting
        sudo rm -f /var/run/docker.sock
        dockerd-rootless-setuptool.sh install 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log" \
          || miss "docker rootless setup failed"
        systemctl --user enable --now docker 2>/dev/null || true
        # node machines: user services must run without an active login
        sudo loginctl enable-linger "$USER" 2>/dev/null || true
      else
        hint "disable rootful, dockerd-rootless-setuptool.sh install, linger"
      fi
    fi
  fi
fi

# ------------------------------------------------------------- herdr
HERDR_WANT="$(conf_get component_herdr no)"
if [[ "$HERDR_WANT" == yes ]]; then
  section "herdr ($MODE) — components/herdr.md"
  if command -v herdr >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/herdr" ]]; then
    ok "herdr installed"
  else
    warn "herdr missing"
    do_or_say bash -c 'curl -fsSL https://herdr.dev/install.sh | sh'
  fi
  # ctrl+b collision: if tmux is also present, give herdr an alternate prefix
  if command -v tmux >/dev/null 2>&1; then
    HCONF="$HOME/.config/herdr/config.toml"
    if [[ -f "$HCONF" ]] && grep -q 'prefix' "$HCONF"; then
      ok "herdr prefix configured (tmux collision handled)"
    else
      warn "tmux present — herdr's default ctrl+b prefix collides"
      if (( INSTALL )); then
        mkdir -p "$(dirname "$HCONF")"
        [[ -f "$HCONF" ]] || printf '[keys]\nprefix = "ctrl+a"\n' > "$HCONF"
        log "set herdr prefix to ctrl+a in $HCONF"
      fi
    fi
  fi
else
  ok "herdr: opt-in, currently '$HERDR_WANT' (flip component_herdr=yes to enable)"
fi

# ---------------------------------------------------------- uutils-ls
# TEMPORARY distro-bug shim (components/uutils-ls.md): resolute's uutils 0.8.0
# `ls --group-directories-first` breaks -t sorting (uutils #12393; fixed in
# 0.9.0). Shadow ONLY ls: pinned 0.9.0 multicall parked OFF-PATH at
# /usr/local/lib/uutils/coreutils, /usr/local/bin/ls symlinked to it.
# Self-removes once dpkg's rust-coreutils >= the pinned version.
UUTILS_VER=0.9.0
UUTILS_SHA256=7fffbe9c835054f1143a5f2a68ef478efb427417163e0410c26c901da15647e5
UUTILS_TGZ="coreutils-${UUTILS_VER}-x86_64-unknown-linux-musl.tar.gz"
UUTILS_URL="https://github.com/uutils/coreutils/releases/download/${UUTILS_VER}/${UUTILS_TGZ}"
UUTILS_BIN=/usr/local/lib/uutils/coreutils
UUTILS_LINK=/usr/local/bin/ls
if [[ "$(conf_get component_uutils_ls yes)" == yes ]]; then
  section "uutils-ls ($MODE) — components/uutils-ls.md"
  PKG_VER="$(dpkg-query -Wf '${Version}' rust-coreutils 2>/dev/null | cut -d- -f1)"
  if [[ "$(uname -m)" != x86_64 ]]; then
    warn "uutils-ls: shim is pinned to x86_64 only — skipping"
  elif dpkg --compare-versions "${PKG_VER:-0}" ge "$UUTILS_VER"; then
    # distro caught up — the shim is obsolete; drop it
    if [[ -e "$UUTILS_LINK" || -e "$UUTILS_BIN" ]]; then
      warn "uutils-ls: distro rust-coreutils ${PKG_VER} >= ${UUTILS_VER} — shim obsolete"
      do_or_say sudo rm -f "$UUTILS_LINK" "$UUTILS_BIN"
      (( INSTALL )) && sudo rmdir --ignore-fail-on-non-empty /usr/local/lib/uutils
    else
      ok "uutils-ls: distro >= ${UUTILS_VER}, shim not needed (flip component_uutils_ls=no to retire the flag)"
    fi
  elif [[ -x "$UUTILS_BIN" && "$(readlink -f "$UUTILS_LINK" 2>/dev/null)" == "$UUTILS_BIN" ]] \
       && "$UUTILS_BIN" ls --version 2>/dev/null | grep -q "$UUTILS_VER"; then
    ok "uutils-ls: ls shadowed at ${UUTILS_VER} (distro has ${PKG_VER:-none})"
  elif (( INSTALL )); then
    warn "uutils-ls: shadow missing — installing ${UUTILS_VER}"
    UUTILS_TMP=$(mktemp -d)
    if curl -fsSL "$UUTILS_URL" -o "$UUTILS_TMP/$UUTILS_TGZ" \
       && echo "$UUTILS_SHA256  $UUTILS_TMP/$UUTILS_TGZ" | sha256sum -c --quiet - \
       && tar -xzf "$UUTILS_TMP/$UUTILS_TGZ" -C "$UUTILS_TMP" --strip-components=1 \
             "${UUTILS_TGZ%.tar.gz}/coreutils"; then
      do_or_say sudo install -D -m 0755 "$UUTILS_TMP/coreutils" "$UUTILS_BIN"
      do_or_say sudo ln -sfn "$UUTILS_BIN" "$UUTILS_LINK"
      "$UUTILS_LINK" --version | grep -q "$UUTILS_VER" \
        && ok "uutils-ls: /usr/local/bin/ls -> ${UUTILS_VER}" \
        || miss "uutils-ls: shadow installed but ls --version mismatch"
    else
      miss "uutils-ls: download/sha256/extract failed ($UUTILS_URL)"
    fi
    rm -rf "$UUTILS_TMP"
  else
    warn "uutils-ls: shadow missing (would download ${UUTILS_VER} and shadow /usr/local/bin/ls)"
  fi
else
  ok "uutils-ls: disabled (component_uutils_ls=no)"
fi

# ------------------------------------------------------------- ollama
# Local LLM runtime backing the `wat` alias (ollama run qwen3-coder:30b) from
# .configs. Default OFF: own installer (not apt), and the models are large.
# The installer adds /usr/local/bin/ollama + a systemd service; we also pull
# the wat model so `wat` works out of the box (skipped in check mode).
# Model is configurable via ollama_model (must match the .bash_aliases alias).
OLLAMA_WANT="$(conf_get component_ollama no)"
if [[ "$OLLAMA_WANT" == yes ]]; then
  section "ollama ($MODE) — components/ollama.md"
  if command -v ollama >/dev/null 2>&1; then
    ok "ollama installed"
  else
    warn "ollama missing"
    do_or_say bash -c 'curl -fsSL https://ollama.com/install.sh | sh'
  fi
  # the model `wat` runs (qwen3-coder:30b ~18 GB — MoE 3B-active, fits the
  # 3090 at ~187 tok/s). Pull is large; only in install mode.
  OLLAMA_MODEL="$(conf_get ollama_model qwen3-coder:30b)"
  if command -v ollama >/dev/null 2>&1 && ollama list 2>/dev/null | grep -qF "$OLLAMA_MODEL"; then
    ok "ollama model $OLLAMA_MODEL present (backs the 'wat' alias)"
  else
    warn "ollama model $OLLAMA_MODEL missing (backs the 'wat' alias)"
    do_or_say ollama pull "$OLLAMA_MODEL" || miss "ollama: pull $OLLAMA_MODEL"
  fi
else
  ok "ollama: opt-in, currently '$OLLAMA_WANT' (flip component_ollama=yes to enable)"
fi

# ------------------------------------------------------------- t3code
# T3 Code (t3.codes): a web/desktop front end for the coding agents already on
# the box — it drives the `claude` CLI and its own login, no key of its own.
# Default OFF: own installer (a self-contained binary from a GitHub release,
# no node), and a listening service is not something every box wants.
# `t3 service install` writes ~/.config/systemd/user/t3code.service and
# RE-RENDERS it on every `t3 update`, so the bind address lives in a drop-in
# the kit owns, reconciled by content (same shape as zram-generator.conf).
# The drop-in goes down BEFORE the first `t3 service install` so the first
# start already binds where the conf says.
T3_WANT="$(conf_get component_t3code no)"
if [[ "$T3_WANT" == yes ]]; then
  section "t3code ($MODE) — components/t3code.md"
  export PATH="$HOME/.local/bin:$PATH"
  T3_HOST="$(conf_get t3code_host 127.0.0.1)"
  T3_PORT="$(conf_get t3code_port 3773)"
  # t3code_tailscale_serve=yes: T3 runs `tailscale serve` itself at start
  # (T3CODE_TAILSCALE_SERVE) — HTTPS on the tailnet name, proxied to the
  # loopback bind, so other devices and the phone reach it with no LAN
  # listener, and the browser gets a secure context (clipboard copy/paste).
  T3_TS="$(conf_get t3code_tailscale_serve no)"
  T3_UNIT="$HOME/.config/systemd/user/t3code.service"
  T3_DROPIN="$HOME/.config/systemd/user/t3code.service.d/setup-kit.conf"
  T3_RELOAD=${HEADLESS_T3_RELOAD:-0}
  if command -v t3 >/dev/null 2>&1; then
    ok "t3 $(t3 --version 2>/dev/null | head -1 | sed "s/^t3 //") ($(command -v t3))"
  else
    warn "t3 missing"
    do_or_say bash -c 'curl -fsSL https://t3.codes/install.sh | sh' || miss "t3code: installer failed (components/t3code.md)"
  fi
  # the provider: t3code has no model access of its own
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI present (t3code's Claude provider — sign in once with: claude auth login)"
  else
    warn "claude CLI not on PATH — t3code fronts Claude Code (component_claude_code=yes, phase 08, then: claude auth login)"
  fi
  # bind address + port, by content
  T3_DROPIN_WANT=$(printf '# written by setup-kit (07-components) — edit hosts/%s.conf, not this file\n[Service]\nEnvironment=T3CODE_HOST=%s\nEnvironment=T3CODE_PORT=%s\n' "$(hostname)" "$T3_HOST" "$T3_PORT")
  [[ "$T3_TS" == yes ]] && T3_DROPIN_WANT+=$'\nEnvironment=T3CODE_TAILSCALE_SERVE=true'
  if [[ -f "$T3_DROPIN" && "$(cat "$T3_DROPIN")" == "$T3_DROPIN_WANT" ]]; then
    ok "t3code bind ${T3_HOST}:${T3_PORT} (drop-in matches)"
  else
    [[ -f "$T3_DROPIN" ]] \
      && warn "t3code bind drop-in drifted — reconciling to ${T3_HOST}:${T3_PORT}" \
      || warn "t3code bind drop-in missing — writing ${T3_HOST}:${T3_PORT}"
    if (( INSTALL )); then
      mkdir -p "$(dirname "$T3_DROPIN")"
      printf '%s\n' "$T3_DROPIN_WANT" > "$T3_DROPIN"
      T3_RELOAD=1
    else
      echo "  [would] write $T3_DROPIN"
    fi
  fi
  # Tailscale Serve needs the tailnet's HTTPS certificates (an admin-console
  # switch) and, from a user service, the operator (`tailscale serve` is
  # state-changing). Both are the human's to set; the doctor names them.
  T3_URL="http://${T3_HOST}:${T3_PORT}"
  if [[ "$T3_TS" == yes ]]; then
    if ! command -v tailscale >/dev/null 2>&1; then
      warn "t3code_tailscale_serve=yes but tailscale missing"
    else
      TS_OP="$(tailscale debug prefs 2>/dev/null | grep -o '"OperatorUser"[^,}]*' | cut -d'"' -f4)"
      if [[ -n "$TS_OP" ]]; then
        ok "tailscale operator: $TS_OP (T3 may run \`tailscale serve\`)"
      else
        warn "tailscale operator not set — T3 can't publish over Tailscale Serve"
        hint "sudo tailscale set --operator=$USER"
      fi
      TS_JSON="$(tailscale status --json 2>/dev/null)"
      TS_NAME="$(printf '%s' "$TS_JSON" | grep -o '"DNSName"[^,}]*' | head -1 | cut -d'"' -f4)"
      # a string match, not `| grep -q`: under pipefail an early-exiting grep
      # SIGPIPEs the writer and a match on a big status reads as a miss
      TS_FLAT="$(printf '%s' "$TS_JSON" | tr -d ' \n')"
      if [[ "$TS_FLAT" == *'"CertDomains":["'* ]]; then
        T3_URL="https://${TS_NAME%.}"
        ok "tailnet HTTPS certificates on ($T3_URL)"
      else
        warn "tailnet HTTPS certificates off — Tailscale Serve can't get a certificate"
        hint "tailnet admin console → DNS → enable MagicDNS and HTTPS Certificates"
      fi
    fi
  fi
  # the user unit — t3 writes, enables and starts it; linger is its business
  # (it enables it, or prints the sudo loginctl line when it cannot)
  if [[ -f "$T3_UNIT" ]] && systemctl --user is-enabled -q t3code.service 2>/dev/null; then
    ok "t3code.service installed + enabled"
    if (( T3_RELOAD )); then
      do_or_say systemctl --user daemon-reload
      do_or_say systemctl --user restart t3code.service || miss "t3code: restart after drop-in change"
    fi
  else
    warn "t3code.service not installed"
    if command -v t3 >/dev/null 2>&1; then
      do_or_say t3 service install || miss "t3code: t3 service install failed (t3 service status)"
    else
      (( INSTALL )) || echo "  [would] t3 service install"
    fi
  fi
  if systemctl --user is-active -q t3code.service 2>/dev/null; then
    ok "t3code.service active — $T3_URL (pair another device: t3 pair$([[ "$T3_TS" == yes ]] && echo ' --tailscale'))"
  elif [[ -f "$T3_UNIT" ]]; then
    warn "t3code.service not running (t3 service status; log path is in its output)"
    do_or_say systemctl --user restart t3code.service || miss "t3code: service would not start (t3 service status)"
  fi
else
  ok "t3code: opt-in, currently '$T3_WANT' (flip component_t3code=yes to enable)"
fi

# ------------------------------------------------------------- git-hub
# Bare repos a worker pushes to instead of GitHub; the human forwards and
# deploys (components/git-hub.md). Mechanism only: which repos, which pushers
# and which deploy command are the host conf's (the machine's role).
if [[ "$(conf_get component_git_hub no)" == yes ]]; then
  section "git-hub ($MODE) — components/git-hub.md"
  source "$KIT_DIR/components/git-hub/lib.sh"
  hub_user_ensure
  if [[ ! -d "$GIT_HUB_ROOT" ]]; then
    warn "hub root $GIT_HUB_ROOT missing"
    (( INSTALL )) && { sudo mkdir -p "$GIT_HUB_ROOT"; sudo chown "$GIT_HUB_USER:$GIT_HUB_USER" "$GIT_HUB_ROOT"; }
  fi
  [[ -z "$GIT_HUB_REPOS" ]] && warn "git_hub_repos empty — the hub holds nothing"
  hub_hook_ensure
  hub_each hub_repo_ensure
  # relative = beside the conf's real file (the machine's role folder)
  HUB_PUSHERS="$(conf_get git_hub_pushers '' | sed "s|^~|$HOME|")"
  [[ -n "$HUB_PUSHERS" && "$HUB_PUSHERS" != /* ]] && HUB_PUSHERS="$(dirname "$(readlink -f "$HOST_CONF")")/$HUB_PUSHERS"
  hub_keys_ensure "$HUB_PUSHERS"
  CLI_LINK="$HOME/.local/bin/git-hub"
  if [[ "$(readlink -f "$CLI_LINK" 2>/dev/null)" == "$KIT_DIR/components/git-hub/git-hub" ]]; then
    ok "git-hub CLI on PATH (git-hub status | forward | stage)"
  else
    warn "git-hub CLI not linked at ${CLI_LINK/#$HOME/\~}"
    (( INSTALL )) && { mkdir -p "$(dirname "$CLI_LINK")"; ln -sfn "$KIT_DIR/components/git-hub/git-hub" "$CLI_LINK"; }
  fi
  hub_release_units_ensure
  hub_token_check
else
  ok "git-hub: opt-in, currently '$(conf_get component_git_hub no)' (flip component_git_hub=yes to host bare repos)"
fi

# ------------------------------------------------------------- codex
# OpenAI's Codex CLI — the second agent t3code fronts (ChatGPT Plus/Pro/
# Business plans include it). Default OFF. A musl binary from OpenAI's own
# installer into ~/.local/bin, no node, no sudo; the installer skips its
# shell-profile edit when ~/.local/bin is already on PATH (it is: claude).
# Login is the USER's — `codex login --device-auth` on a headless box — the
# kit only reports it, same policy as `claude auth login`.
CODEX_WANT="$(conf_get component_codex no)"
if [[ "$CODEX_WANT" == yes ]]; then
  section "codex ($MODE) — components/codex.md"
  export PATH="$HOME/.local/bin:$PATH"
  if command -v codex >/dev/null 2>&1; then
    ok "$(codex --version 2>/dev/null | head -1) ($(command -v codex))"
  else
    warn "codex missing"
    do_or_say bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh' || miss "codex: installer failed (components/codex.md)"
  fi
  if command -v codex >/dev/null 2>&1; then
    if codex login status >/dev/null 2>&1; then
      ok "codex logged in ($(codex login status 2>/dev/null | head -1))"
    else
      warn "codex not logged in — enable device-code login in ChatGPT security settings, then: codex login --device-auth"
    fi
  fi
else
  ok "codex: opt-in, currently '$CODEX_WANT' (flip component_codex=yes to enable)"
fi

# ------------------------------------------------------------- aws-cli v2
# Same flag as the dev-cloud apt group; apt's awscli is v1 and cannot do the
# sso_session logins .configs/bin/sso needs, so v2 comes from Amazon's bundle.
if [[ "$(conf_get group_dev_cloud yes)" == yes ]]; then
  section "aws-cli v2 ($MODE) — components/aws-cli.md"
  AWS_VER="$(command -v aws >/dev/null 2>&1 && aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9.]*\).*|\1|p')"
  if dpkg -s awscli >/dev/null 2>&1; then
    warn "apt awscli (v1) installed — shadows v2 on PATH; removing"
    do_or_say sudo apt-get remove -y awscli || miss "aws-cli: apt-get remove awscli"
  fi
  case "$AWS_VER" in
    2.*) ok "aws-cli v$AWS_VER ($(command -v aws))" ;;
    *)   warn "aws-cli v2 missing (have: ${AWS_VER:-none}) — installing Amazon's bundle to /usr/local/bin"
         do_or_say aws_cli_v2_install || miss "aws-cli v2: bundle install failed (components/aws-cli.md)" ;;
  esac
else
  ok "aws-cli: group_dev_cloud is off — skipped"
fi

# ------------------------------------------------------------- whisper
# Speech-to-text for the audio archive (yda downloads → searchable text).
# faster-whisper via the whisper-ctranslate2 CLI: on NVIDIA it beats
# whisper.cpp (~12x vs ~8x realtime, same weights); CUDA runtime comes as pip
# wheels inside the pipx venv — no system CUDA toolkit. Opt-in: the model is
# the real cost (~3 GB). .configs ships the `transcribe`/`ydat` glue.
WHISPER_WANT="$(conf_get component_whisper no)"
if [[ "$WHISPER_WANT" == yes ]]; then
  section "whisper ($MODE) — components/whisper.md"
  WHISPER_VENV="$HOME/.local/share/pipx/venvs/whisper-ctranslate2"
  if command -v whisper-ctranslate2 >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/whisper-ctranslate2" ]]; then
    ok "whisper-ctranslate2 installed"
  else
    warn "whisper-ctranslate2 missing"
    do_or_say pipx install whisper-ctranslate2 || miss "whisper: pipx install whisper-ctranslate2"
  fi
  # CUDA runtime as venv-local pip wheels (cuBLAS + cuDNN 9); the .configs
  # `transcribe` wrapper exports LD_LIBRARY_PATH into these — CTranslate2
  # dlopens them, nothing system-wide changes.
  if nvidia_wanted; then
    if [[ -x "$WHISPER_VENV/bin/python" ]] \
       && "$WHISPER_VENV/bin/python" -c 'import nvidia.cublas.lib, nvidia.cudnn.lib' 2>/dev/null; then
      ok "whisper CUDA wheels present (cuBLAS/cuDNN in venv)"
    else
      warn "whisper CUDA wheels missing (GPU run would fail; CPU still works)"
      do_or_say pipx inject whisper-ctranslate2 nvidia-cublas-cu12 'nvidia-cudnn-cu12==9.*' \
        || miss "whisper: pipx inject nvidia-cublas-cu12 nvidia-cudnn-cu12"
    fi
  fi
  # Pre-warm the model cache so first real use isn't a surprise ~3 GB pull.
  # local_files_only=True is an offline cache probe; it also resolves the
  # distil naming (distil-large-v3 -> Systran/faster-distil-whisper-…), so
  # don't guess the hub dir by hand. Keep whisper_model in sync with the
  # .configs transcribe wrapper's default.
  WHISPER_MODEL="$(conf_get whisper_model large-v3)"
  if [[ -x "$WHISPER_VENV/bin/python" ]] \
     && "$WHISPER_VENV/bin/python" -c "from faster_whisper import download_model; download_model('$WHISPER_MODEL', local_files_only=True)" 2>/dev/null; then
    ok "whisper model $WHISPER_MODEL cached"
  else
    warn "whisper model $WHISPER_MODEL not cached (~3 GB download)"
    do_or_say "$WHISPER_VENV/bin/python" -c "from faster_whisper import download_model; download_model('$WHISPER_MODEL')" \
      || miss "whisper: download model $WHISPER_MODEL"
  fi
else
  ok "whisper: opt-in, currently '$WHISPER_WANT' (flip component_whisper=yes to enable)"
fi

# ------------------------------------------------------------- chatterbox
# Chatterbox-TTS, the audiobook line's renderer (components/chatterbox.md).
# A DEDICATED pyenv virtualenv named `chatterbox`: chatterbook/build_book.sh,
# audiobook/scripts/render-book.sh and wbt all pin
# ~/.pyenv/versions/chatterbox/bin/python3 (name, not patch — stable across
# machines). Pinned package version: chatterbox-tts pins torch/transformers
# itself, so the one number that decides the whole venv is this one; override
# with chatterbox_version= in the host conf when a render proves a newer one.
CHATTERBOX_WANT="$(conf_get component_chatterbox no)"
if [[ "$CHATTERBOX_WANT" == yes ]]; then
  section "chatterbox ($MODE) — components/chatterbox.md"
  CB_VER="$(conf_get chatterbox_version 0.1.7)"
  CB_PY="$HOME/.pyenv/versions/chatterbox/bin/python3"
  CB_SRC="$HOME/git/audiobook/chatterbook"     # the engine checkout (clone_repos → audiobook, its bootstrap clones chatterbook)
  export PYENV_ROOT="$HOME/.pyenv" PATH="$HOME/.pyenv/bin:$PATH"
  CB_BASE="$(pyenv versions --bare 2>/dev/null | grep -E '^3\.12(\.|$)' | grep -v / | tail -1)"
  if [[ ! -x "$CB_PY" ]]; then
    warn "chatterbox virtualenv missing (~/.pyenv/versions/chatterbox)"
    if (( INSTALL )); then
      if [[ -z "$CB_BASE" ]]; then
        fail "no pyenv 3.12 to build the chatterbox venv from — run 04-languages (lang_python=yes)"
      else
        pyenv virtualenv "$CB_BASE" chatterbox 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log" \
          || miss "chatterbox: pyenv virtualenv $CB_BASE chatterbox"
      fi
    else
      hint "pyenv virtualenv ${CB_BASE:-3.12} chatterbox && pip install chatterbox-tts==$CB_VER"
    fi
  else
    ok "chatterbox virtualenv present"
  fi
  if [[ -x "$CB_PY" ]]; then
    # the package pins torch==2.6.0 (CUDA 12.4 wheel from PyPI on Linux),
    # torchaudio, transformers, numpy<2 — one pin, everything else follows
    # The probe constructs what from_pretrained() constructs, not just the
    # import: resemble-perth's watermarker is imported inside a try/except
    # that leaves `perth.PerthImplicitWatermarker = None` when pkg_resources
    # is missing (a 3.12 venv has no setuptools), and the model then dies
    # with "'NoneType' object is not callable" on its first load — the
    # imports all succeed (2026-09-16, ai-3090). setuptools<82 is on the
    # line: 82 removed pkg_resources, so a bare `setuptools` fixes nothing.
    if "$CB_PY" -c 'import torch, torchaudio, perth; from chatterbox.tts_turbo import ChatterboxTurboTTS; assert perth.PerthImplicitWatermarker is not None' 2>/dev/null; then
      ok "chatterbox venv deps (chatterbox-tts, torch, torchaudio, perth watermarker) present"
    else
      warn "chatterbox venv deps missing or perth watermarker unimportable"
      do_or_say "$CB_PY" -m pip install --quiet "chatterbox-tts==$CB_VER" 'setuptools<82' \
        || miss "chatterbox: pip install chatterbox-tts==$CB_VER setuptools<82"
    fi
    # chatterbook (the engine's own package) as an editable install, asked from
    # / — from inside the checkout every interpreter can import ./chatterbook
    # whether or not it is installed (chatterbook/README.md, check-install.sh)
    if (cd / && "$CB_PY" -c 'import chatterbook' 2>/dev/null); then
      ok "chatterbook importable from the chatterbox venv (editable install)"
    elif [[ -f "$CB_SRC/pyproject.toml" ]]; then
      warn "chatterbook not installed in the chatterbox venv"
      do_or_say "$CB_PY" -m pip install --quiet -e "$CB_SRC" \
        || miss "chatterbox: pip install -e $CB_SRC"
    else
      warn "chatterbook not installed and no checkout at $CB_SRC (clone_repos → audiobook, then audiobook/scripts/bootstrap)"
      miss "chatterbox: chatterbook checkout missing at $CB_SRC"
    fi
    # the GPU: report only. Ampere+ and the default cu124 wheel agree; a card
    # the wheel can't drive is a different component's problem (tts/kokoro
    # has the cu118 dance) and a render would say so on its first chunk.
    if nvidia_wanted; then
      "$CB_PY" -c 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)' 2>/dev/null \
        && ok "chatterbox torch sees the GPU" \
        || warn "chatterbox torch can't see the GPU (CUDA wheel vs driver?) — renders would run on CPU or fail"
    fi
    # Pre-warm the Turbo weights so the first render isn't a surprise pull.
    # local_files_only=True is an offline cache probe against the same hub
    # repo from_pretrained() uses; the id is read from the package, not copied.
    CB_PROBE='from huggingface_hub import snapshot_download; from chatterbox import tts_turbo as t; snapshot_download(t.REPO_ID, local_files_only=True)'
    if "$CB_PY" -c "$CB_PROBE" >/dev/null 2>&1; then
      ok "chatterbox Turbo weights cached (~/.cache/huggingface)"
    else
      warn "chatterbox Turbo weights not cached (download on first render)"
      do_or_say "$CB_PY" -c "${CB_PROBE/, local_files_only=True/}" \
        || miss "chatterbox: download Turbo weights (huggingface — gated? set HF_TOKEN)"
    fi
  fi
else
  ok "chatterbox: opt-in, currently '$CHATTERBOX_WANT' (flip component_chatterbox=yes on a box that renders audiobooks)"
fi

# ------------------------------------------------------------- mtga (wine)
# MTG Arena under Wine. Install-only: fetch WotC's bootstrap installer and run
# it once (GUI; downloads the ~14 GB client into ~/.wine). The kit never owns
# that data. Done = MTGA.exe present. See components/mtga.md. The launcher
# self-update loop fix is deliberately NOT handled here — see that doc's caveat.
MTGA_WANT="$(conf_get component_mtga no)"
if [[ "$MTGA_WANT" == yes ]]; then
  section "mtga ($MODE) — components/mtga.md"
  MTGA_EXE="$HOME/.wine/drive_c/Program Files/Wizards of the Coast/MTGA/MTGA.exe"
  MTGA_URL="https://mtgarena.downloads.wizards.com/Live/Windows32/MTGAInstaller.exe"
  if [[ -f "$MTGA_EXE" ]]; then
    ok "MTGA installed (MTGA.exe present)"
    # Launcher entry: Wine drops the Start-Menu shortcut in a nested subdir
    # GNOME's app grid won't surface, with a themed icon name that needs a
    # cache rebuild (else: gear icon). Reconcile to ONE top-level entry with
    # an absolute icon path; hide the nested original (NoDisplay). Reconciled
    # by content — re-runs converge even if Wine rewrites the nested file.
    APPS="$HOME/.local/share/applications"
    NESTED="$APPS/wine/Programs/MTG Arena/MTG Arena.desktop"
    FLAT="$APPS/mtga.desktop"
    if [[ -f "$NESTED" ]]; then
      icon="$(awk -F= '/^Icon=/{print $2; exit}' "$NESTED")"
      icon_abs=""
      for d in 256x256 192x192 128x128 96x96 64x64 48x48; do
        p="$HOME/.local/share/icons/hicolor/$d/apps/$icon.png"
        [[ -f "$p" ]] && { icon_abs="$p"; break; }
      done
      # desired flat = nested minus NoDisplay, with icon → absolute path
      desired="$(grep -v '^NoDisplay=' "$NESTED")"
      [[ -n "$icon_abs" ]] && desired="$(printf '%s\n' "$desired" | sed "s|^Icon=.*|Icon=$icon_abs|")"
      if [[ "$(cat "$FLAT" 2>/dev/null)" == "$desired" ]] && grep -q '^NoDisplay=true' "$NESTED"; then
        ok "MTGA launcher entry positioned (flat + absolute icon, nested hidden)"
      else
        warn "MTGA launcher entry needs positioning (nested shortcut unsurfaced / gear icon)"
        if (( INSTALL )); then
          printf '%s\n' "$desired" > "$FLAT"
          grep -q '^NoDisplay=' "$NESTED" || printf 'NoDisplay=true\n' >> "$NESTED"
          update-desktop-database "$APPS" 2>/dev/null
          gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null
          ok "positioned MTGA launcher entry"
        fi
      fi
    else
      warn "MTGA installed but no Wine launcher shortcut yet — run MTGA once so Wine generates it"
    fi
  elif ! command -v wine >/dev/null 2>&1; then
    warn "MTGA wanted but wine missing — set group_wine=yes (manifests/apt/wine.list)"
    miss "mtga: wine absent (flip group_wine=yes)"
  else
    warn "MTGA not installed — fetch + run WotC installer (GUI, downloads ~14 GB)"
    # GUI installer: needs a desktop session; runs once in install mode only.
    do_or_say bash -c 'curl -fL "'"$MTGA_URL"'" -o /tmp/MTGAInstaller.exe && wine /tmp/MTGAInstaller.exe' \
      || miss "mtga: installer fetch/run failed (needs a desktop session)"
  fi
else
  ok "mtga: opt-in, currently '$MTGA_WANT' (flip component_mtga=yes to enable)"
fi

# ------------------------------------------------------------- steam launcher entry
# steam-installer (multiverse) ships a valid SYSTEM entry
# (/usr/share/applications/steam.desktop, Exec=/usr/bin/steam). A box migrated
# off the dropped steam-launcher (see manifests/apt/dropped.list) carries a
# stale USER-level override:
#   ~/.local/share/applications/steam.desktop -> …/Steam/deb-installer/steam.desktop
# whose Exec=/usr/games/steam does not exist under the installer. Because a user
# entry overrides the system one by desktop-ID, GNOME hides Steam entirely — no
# app-grid icon, unsearchable. Reconcile: drop the stale override so the valid
# system entry surfaces. Idempotent — once gone (or if the user entry's Exec
# resolves), nothing to do. Non-destructive: a valid user override is left alone.
if group_on games; then
  SYS_STEAM=/usr/share/applications/steam.desktop
  USR_STEAM="$HOME/.local/share/applications/steam.desktop"
  if [[ -e "$SYS_STEAM" && ( -e "$USR_STEAM" || -L "$USR_STEAM" ) ]]; then
    section "steam launcher entry ($MODE)"
    exec_bin="$(awk -F'[= ]' '/^Exec=/{print $2; exit}' "$USR_STEAM" 2>/dev/null)"
    if [[ -n "$exec_bin" && ! -x "$exec_bin" ]]; then
      warn "stale user steam.desktop overrides system entry (Exec=$exec_bin missing) — Steam hidden from GNOME"
      if (( INSTALL )); then
        rm -f "$USR_STEAM"
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
        ok "removed stale steam.desktop override — system entry now surfaces"
      fi
    else
      ok "user steam.desktop Exec resolves ($exec_bin) — leaving as-is"
    fi
  fi
fi

# Dictation, OCR and TTS default on because .configs ships the tools they
# serve (the Alt+s wrapper, ocrscr, the clipboard TTS client). On a box
# without .configs (configs=no) nothing would call them: default off there.
CFG_DEF=yes; [[ "$(conf_get configs yes)" == no ]] && CFG_DEF=no

# ------------------------------------------------------------- dictation
# Speech-to-text chain (CPU-only — vosk lgraph model; NOT GPU-gated like
# TTS). .configs ships hotkeys + wrapper; this provisions what they call:
# the nerd-dictation repo, vosk in the pyenv python, and the model.
# Without it: the .configs Alt+s hotkey fires but the wrapper can't find vosk.
if [[ "$(conf_get component_dictation "$CFG_DEF")" == yes ]]; then
  section "dictation ($MODE) — nerd-dictation + vosk"
  ND="$HOME/git/nerd-dictation"          # wrapper's portable fallback path
  if [[ -x "$ND/nerd-dictation" ]]; then
    ok "nerd-dictation repo at $ND"
  else
    warn "nerd-dictation repo missing"
    do_or_say git clone --depth 1 https://github.com/ideasman42/nerd-dictation.git "$ND"
  fi
  # vosk lives in a DEDICATED `vosk` pyenv venv — not pyenv global (which is
  # `system` now), and the wrapper prefers this venv deterministically.
  export PYENV_ROOT="$HOME/.pyenv" PATH="$HOME/.pyenv/bin:$PATH"
  VOSK_PY="$HOME/.pyenv/versions/vosk/bin/python"
  BASE12="$(pyenv versions --bare 2>/dev/null | grep -E '^3\.12(\.|$)' | grep -v / | tail -1)"
  if [[ ! -x "$VOSK_PY" ]]; then
    warn "vosk virtualenv missing"
    if (( INSTALL )); then
      [[ -n "$BASE12" ]] && pyenv virtualenv "$BASE12" vosk 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log" \
        || fail "no 3.12 interpreter to build the vosk venv — run 04-languages"
    fi
  else
    ok "vosk virtualenv present"
  fi
  if [[ -x "$VOSK_PY" ]]; then
    "$VOSK_PY" -c 'import vosk' 2>/dev/null && ok "vosk importable in vosk venv" \
      || { warn "vosk not in vosk venv"; do_or_say "$VOSK_PY" -m pip install --quiet vosk || miss "pip install vosk"; }
  fi
  NDCFG="$HOME/.config/nerd-dictation"
  MODEL="vosk-model-en-us-0.22-lgraph"   # 205 MB; the .configs README default
  if [[ -d "$NDCFG/models/$MODEL" ]]; then
    ok "vosk model $MODEL present"
  else
    warn "vosk model missing (~205 MB download)"
    if (( INSTALL )); then
      mkdir -p "$NDCFG/models"
      curl -fL "https://alphacephei.com/vosk/models/$MODEL.zip" -o "/tmp/$MODEL.zip" \
        && unzip -q "/tmp/$MODEL.zip" -d "$NDCFG/models/" \
        && rm -f "/tmp/$MODEL.zip" \
        || miss "vosk model download: $MODEL"
    fi
  fi
  if [[ "$(readlink "$NDCFG/model" 2>/dev/null)" == "models/$MODEL" ]]; then
    ok "active model → $MODEL"
  else
    warn "model symlink not set"
    do_or_say ln -sfn "models/$MODEL" "$NDCFG/model"
  fi
  # Wayland caveat: nerd-dictation types via xdotool (X11). 26.04 defaults
  # to Wayland — needs ydotool/wtype or an Xorg session.
  # Wayland: nerd-dictation types through ydotool. Three parts, all needed:
  # the package (ydotool + ydotoold + a udev rule making /dev/uinput group
  # 'input'), membership of that group (takes effect at next login), and the
  # user service running ydotoold (socket in $XDG_RUNTIME_DIR, where the
  # client looks). The .configs wrapper picks YDOTOOL on Wayland by itself.
  if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
    if pkg_installed ydotool; then ok "ydotool installed (Wayland typing)"
    else warn "ydotool missing — dictation on Wayland can listen but can't type"; apt_install ydotool; fi
    if id -nG "$USER" 2>/dev/null | grep -qw input; then ok "user in input group (/dev/uinput)"
    else
      warn "user not in input group — ydotool can't open /dev/uinput (takes effect at next login)"
      do_or_say sudo usermod -aG input "$USER"
    fi
    # The input group is not enough: ydotoold runs under the systemd --user
    # manager, and with Linger=yes that manager never restarts on logout, so
    # it keeps login-time groups forever (2026-09-05: relogin changed nothing).
    # A uaccess ACL on /dev/uinput is per-uid for the active seat — works now,
    # survives relogins, needs no group. 72- so it precedes 73-seat-late.rules,
    # which is what turns the tag into the ACL.
    UI_RULE="${UINPUT_RULE:-/etc/udev/rules.d/72-uinput-uaccess.rules}"   # overridable for tests/
    UI_WANT='KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess"'
    if [[ -f "$UI_RULE" && "$(cat "$UI_RULE")" == "$UI_WANT" ]]; then
      ok "/dev/uinput uaccess rule present"
    else
      warn "/dev/uinput uaccess rule missing — the seat user needs an ACL on it (group alone doesn't reach ydotoold under linger)"
      if (( INSTALL )); then
        printf '%s\n' "$UI_WANT" | sudo tee "$UI_RULE" >/dev/null
        sudo udevadm control --reload && sudo udevadm trigger --action=add --name-match=uinput \
          && log "installed $UI_RULE and re-added /dev/uinput"
      else
        printf '  %s[would]%s write %s and re-add /dev/uinput\n' "$C_DIM" "$C_RST" "$UI_RULE"
      fi
    fi
    if systemctl --user is-active ydotool.service >/dev/null 2>&1; then ok "ydotoold running (ydotool.service)"
    elif pkg_installed ydotool; then
      if [[ -w /dev/uinput ]]; then
        warn "ydotool.service not running — starting ydotoold"
        do_or_say systemctl --user enable --now ydotool.service
      else
        warn "/dev/uinput not writable by you yet — ydotoold deferred (re-run after the udev rule lands)"
        (( INSTALL )) && systemctl --user enable ydotool.service >/dev/null 2>&1
      fi
    else
      printf '  %s[would]%s enable ydotool.service (ydotoold) once the package is in\n' "$C_DIM" "$C_RST"
    fi
  fi
fi

# ------------------------------------------------------------- ocr (screen)
# ocrscr (.configs/bin) = select region → tesseract → clipboard. CPU-only,
# default on. Installs BOTH session toolsets (X11 + Wayland) — the install
# is often driven from a different session than the one ocrscr runs in, and
# a box may offer both at the login screen; ocrscr picks the right pair at
# click-time. All small CLIs.
if [[ "$(conf_get component_ocr "$CFG_DEF")" == yes ]]; then
  section "ocr (screen) ($MODE)"
  # tesseract+imagemagick always; gnome-screenshot for GNOME (Wayland or X11
  # — Mutter can't do grim/slurp); maim/xsel for plain X11; grim/slurp/
  # wl-clipboard for wlroots Wayland. Install all — small, and ocrscr picks
  # the right one per compositor at click-time.
  for d in tesseract-ocr imagemagick python3-gi xdg-desktop-portal-gnome maim xsel grim slurp wl-clipboard; do
    if pkg_installed "$d"; then ok "ocr dep $d"
    else warn "ocr dep $d missing"; apt_install "$d"; fi
  done
fi

# ------------------------------------------------------------- tts (kokoro)
# Clipboard TTS server (kokoro neural TTS + sounddevice, HEAVY — pulls
# torch, ~6 GB). Default ON: .configs ships the clipboard-TTS client (the
# Flutter control window) plus the server symlinks unconditionally, and the
# client is useless without this backend. Opt OUT with component_tts=no on a
# box with no desktop session to speak from — a worker (2026-09-16, ai-3090:
# the audiobook line uses Chatterbox, not kokoro; the venv was 5.9 GB of
# nothing). (kokoro ~82M runs on
# GPU when torch can drive the card, else CPU — see the torch-backend note
# below.) Deps live in a DEDICATED pyenv virtualenv named
# `kokoro-tts` (~/.pyenv/versions/kokoro-tts), NOT pyenv global — so the
# .configs shebangs (#!~/.pyenv/versions/kokoro-tts/bin/python) resolve regardless
# of global (which stays system for a clean prompt), the deps don't pollute
# the bare 3.12, and the path is stable across machines (name, not patch).
if [[ "$(conf_get component_tts "$CFG_DEF")" == yes ]]; then
section "tts (kokoro) ($MODE)"
for d in libsndfile1 libportaudio2 espeak-ng; do
  pkg_installed "$d" && ok "tts dep $d" || { warn "tts dep $d missing"; apt_install "$d"; }
done
export PYENV_ROOT="$HOME/.pyenv" PATH="$HOME/.pyenv/bin:$PATH"
TTS_PY="$HOME/.pyenv/versions/kokoro-tts/bin/python"
BASE12="$(pyenv versions --bare 2>/dev/null | grep -E '^3\.12(\.|$)' | grep -v / | tail -1)"
if [[ ! -x "$TTS_PY" ]]; then
  warn "tts virtualenv missing"
  if (( INSTALL )); then
    if [[ -z "$BASE12" ]]; then
      fail "no 3.12 interpreter to build the kokoro-tts venv from — run 04-languages"
    else
      pyenv virtualenv "$BASE12" kokoro-tts 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log" \
        || miss "tts: pyenv virtualenv $BASE12 kokoro-tts"
    fi
  fi
else
  ok "tts virtualenv present"
fi
if [[ -x "$TTS_PY" ]]; then
  if "$TTS_PY" -c 'import kokoro,soundfile,sounddevice' 2>/dev/null; then
    ok "tts venv deps (kokoro, soundfile, sounddevice) present"
  else
    warn "tts venv deps missing"
    do_or_say "$TTS_PY" -m pip install --quiet kokoro soundfile sounddevice \
      || miss "tts: pip install into tts venv"
  fi
  # torch backend: prefer the GPU, fall back to CPU only when it genuinely
  # can't drive the card. kokoro auto-uses CUDA whenever torch sees a usable
  # GPU, but the DEFAULT torch wheel tracks the newest cuDNN, which has dropped
  # older GPUs (cuDNN 9.12 / torch 2.8 removed Pascal sm_61, e.g. GTX 10xx):
  # pipeline init throws `cuDNN ... not compatible with devices with SM < 7.5`
  # and the server exits 0 via its fatal handler — systemd sees success, never
  # restarts, TTS is silently dead. But the cu118 wheel line (through torch
  # 2.7.1) STILL ships sm_61 kernels + a Pascal-capable cuDNN (9.1), so an old
  # GPU CAN run kokoro — it just needs that wheel. So we don't guess from the
  # compute-cap number; we actually RUN a cuDNN op on the GPU and let the result
  # decide: keep a working default wheel, drop to the cu118 wheel if it fails,
  # and pin CPU only if even cu118 can't drive the card (or there's no usable
  # GPU). cu118 install relies on the general torch deps already present from the
  # kokoro install above (the cu118 index doesn't mirror PyPI), hence its order.
  gpu_runs_kokoro() {  # 0 = a cuDNN op actually ran on the GPU; nonzero = no
    "$TTS_PY" - <<'PY' 2>/dev/null
import sys, torch, torch.nn as nn
if not torch.cuda.is_available(): sys.exit(3)          # CPU-only wheel / no CUDA
try:
    nn.LSTM(16, 16, 2).cuda()(torch.randn(5, 4, 16, device='cuda'))
    torch.cuda.synchronize()                            # kokoro's exact failing path
except Exception:
    sys.exit(1)                                         # CUDA present, cuDNN refuses this GPU
PY
  }
  pin_cpu_torch() {
    # --force-reinstall --no-deps: the cpu wheel shares the version string with
    # the cuda one, so pip would otherwise treat the cuda build as satisfying
    # `torch`; deps are already present, so the cpu-only index needs nothing else.
    do_or_say "$TTS_PY" -m pip install --quiet --force-reinstall --no-deps \
      --index-url https://download.pytorch.org/whl/cpu torch \
      || miss "tts: pin CPU-only torch in kokoro-tts venv"
  }
  # When even cu118 can't drive the card, the CPU wheel is the deliberate end
  # state — but a later pass can't tell that from a wrong wheel, so it would
  # retry cu118 + re-pin CPU forever (breaks convergence). Remember the verdict
  # in a marker keyed by GPU identity (content, not mtime): same GPU → settled;
  # different GPU → probe again.
  TORCH_CPU_MARK="$HOME/.pyenv/versions/kokoro-tts/.torch-cpu-pinned"
  gpu_fp() { lspci -nn 2>/dev/null | grep -iE 'vga|3d controller' | sort; }
  torch_is_cpu() { "$TTS_PY" -c 'import torch,sys; sys.exit(1 if torch.version.cuda else 0)' 2>/dev/null; }
  if nvidia_wanted; then
    if gpu_runs_kokoro; then
      rm -f "$TORCH_CPU_MARK"
      ok "tts torch: runs kokoro on the GPU (cuDNN op verified)"
    elif ! { nvidia_live && nvidia-smi -L >/dev/null 2>&1; }; then
      # NO VERDICT from a broken driver: a failed probe here says nothing about
      # the GPU. Deciding anyway is how a transient outage got CPU torch pinned
      # on a healthy RTX 3090 (2026-07-24). Leave torch alone, flag it.
      warn "tts torch: nvidia driver not operational — GPU probe unusable, leaving torch as-is"
      miss "tts: GPU probe skipped (driver down) — re-run install once nvidia-smi works"
    elif [[ -f "$TORCH_CPU_MARK" ]] && [[ "$(cat "$TORCH_CPU_MARK")" == "$(gpu_fp)" ]] \
         && torch_is_cpu; then
      ok "tts torch: CPU-only pinned (cu118 already failed on this GPU)"
    elif torch_is_cpu; then
      # CPU wheel on a live GPU with no pin verdict (e.g. pinned during a
      # driver outage): restore the default wheel; next branch/pass judges it.
      warn "tts torch: CPU wheel but the GPU driver works — restoring default CUDA wheel"
      do_or_say "$TTS_PY" -m pip install --quiet --force-reinstall torch \
        || miss "tts: restore default torch wheel"
      if gpu_runs_kokoro; then
        rm -f "$TORCH_CPU_MARK"
        ok "tts torch: runs kokoro on the GPU (default wheel restored)"
      else
        warn "tts torch: default wheel restored but probe still failing — next pass tries cu118"
      fi
    else
      warn "tts torch: default wheel can't drive this GPU — trying Pascal-era cu118 wheel"
      do_or_say "$TTS_PY" -m pip install --quiet \
        --index-url https://download.pytorch.org/whl/cu118 torch==2.7.1 \
        || miss "tts: install cu118 torch (Pascal-supporting)"
      if gpu_runs_kokoro; then
        rm -f "$TORCH_CPU_MARK"
        ok "tts torch: GPU via cu118 wheel (older cuDNN, supports Pascal/sm_61)"
      else
        warn "tts torch: GPU still unusable after cu118 — pinning CPU-only torch"
        pin_cpu_torch
        (( INSTALL )) && gpu_fp > "$TORCH_CPU_MARK"
      fi
    fi
  else
    # No usable GPU (none present, or a legacy card the driver won't back): a
    # CUDA wheel is dead weight that can't run here — pin CPU-only torch.
    if "$TTS_PY" -c 'import torch,sys; sys.exit(1 if torch.version.cuda else 0)' 2>/dev/null; then
      ok "tts torch is CPU-only build (no usable GPU)"
    else
      warn "tts torch is a CUDA build but no usable GPU — pinning CPU-only torch"
      pin_cpu_torch
    fi
  fi
fi
else
  ok "tts (kokoro): disabled (component_tts=no)"
fi

# ------------------------------------------------------------- clipboard
# Copy/paste that behaves in GNOME Terminal on 26.04 (components/clipboard.md):
# middle-click PRIMARY paste back on, and pbcopy/pbpaste/copy in every bash.
if [[ "$(conf_get component_clipboard yes)" == yes ]]; then
  section "clipboard ($MODE) — components/clipboard.md"
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || ! command -v gsettings >/dev/null 2>&1; then
    warn "no DBus session — middle-click primary paste not checked (run while logged in at the desktop)"
  elif [[ "$(gsettings get org.gnome.desktop.interface gtk-enable-primary-paste 2>/dev/null)" == true ]]; then
    ok "middle-click primary paste on"
  else
    warn "middle-click primary paste off (26.04's default)"
    do_or_say gsettings set org.gnome.desktop.interface gtk-enable-primary-paste true
  fi
  CB_SRC="$KIT_DIR/components/clipboard.bash"
  CB_LINK="$HOME/.local/share/setup-kit/clipboard.bash"
  if [[ -L "$CB_LINK" && "$(readlink -f "$CB_LINK")" == "$(readlink -f "$CB_SRC")" ]]; then
    ok "clipboard.bash linked"
  else
    warn "clipboard.bash not linked at ${CB_LINK/#$HOME/\~}"
    do_or_say mkdir -p "$(dirname "$CB_LINK")"
    do_or_say ln -sfnT "$CB_SRC" "$CB_LINK"
  fi
  # A symlinked ~/.bashrc is someone else's file (the owner's .configs): check
  # it, never write through it.
  # Match a source command at the start of a line or after a shell separator;
  # comments and a bare filename mention do not load the clipboard functions.
  if grep -Eq "^[[:space:]]*([^#]*(&&|\\|\\||;)[[:space:]]*)?(source|\\.)[[:space:]]+[^#;]*clipboard\\.bash([[:space:]\"';]|$)" "$HOME/.bashrc" 2>/dev/null; then
    ok "~/.bashrc sources clipboard.bash"
  elif [[ -L "$HOME/.bashrc" ]]; then
    warn "~/.bashrc is managed elsewhere ($(readlink -f "$HOME/.bashrc")) and doesn't source clipboard.bash — add it there"
  else
    warn "~/.bashrc doesn't source clipboard.bash"
    if (( INSTALL )); then
      printf '\n# setup-kit: pbcopy/pbpaste/copy (components/clipboard.md)\n[ -f ~/.local/share/setup-kit/clipboard.bash ] && . ~/.local/share/setup-kit/clipboard.bash\n' >> "$HOME/.bashrc"
      log "appended the clipboard.bash source line to ~/.bashrc"
    fi
  fi
fi

# ------------------------------------------------------------- lid-ignore
# A laptop serving as a node (lid shut, reached over ssh) must not suspend
# when the lid closes. Role choice, not a hardware fact — opt-in per host —
# and refused on anything that is not a laptop, where the drop-in is noise.
# Reconciled by CONTENT (like zram-generator.conf): all three lid handlers,
# or a docked/AC edge case still suspends.
LID_DROPIN="${KIT_LID_DROPIN:-/etc/systemd/logind.conf.d/10-lid-ignore.conf}"
LID_WANT=$'[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore'
if [[ "$(conf_get component_lid_ignore no)" == yes ]]; then
  section "lid-ignore ($MODE) — components/lid-ignore.md"
  LID_CHASSIS="$(hostnamectl chassis 2>/dev/null || true)"
  if [[ "$LID_CHASSIS" != laptop && "$LID_CHASSIS" != convertible ]]; then
    warn "lid-ignore: chassis is '${LID_CHASSIS:-unknown}', not a laptop — refusing (drop component_lid_ignore from this host's conf)"
  elif [[ -f "$LID_DROPIN" && "$(cat "$LID_DROPIN")" == "$LID_WANT" ]]; then
    ok "lid-ignore: $LID_DROPIN in place (lid close ignored on AC, battery, docked)"
  else
    [[ -f "$LID_DROPIN" ]] \
      && warn "lid-ignore: $LID_DROPIN drifted — reconciling" \
      || warn "lid-ignore: $LID_DROPIN missing — closing the lid would suspend"
    if (( INSTALL )); then
      sudo mkdir -p "$(dirname "$LID_DROPIN")"
      printf '%s\n' "$LID_WANT" | sudo tee "$LID_DROPIN" >/dev/null
      # reload, never restart: restarting logind tears down the graphical
      # session (systemd >= 254 re-reads logind.conf.d on reload)
      sudo systemctl reload systemd-logind \
        && ok "lid-ignore: logind reloaded" \
        || miss "lid-ignore: systemctl reload systemd-logind (takes effect at next boot)"
    fi
  fi
else
  ok "lid-ignore: disabled (component_lid_ignore=no) — lid close follows logind defaults"
fi

# --------------------------------------------- tts flutter client bundle
# .configs ships the Flutter control-window SOURCE only; build/ is gitignored,
# so a fresh machine has no usable client binary until we compile it here. The
# ~/bin/tts-clipboard-flutter wrapper execs the bundle's tts_client. Needs the
# flutter SDK (05) and the .configs checkout (06), both of which precede us.
FLUTTER_BIN="$HOME/development/flutter/bin/flutter"
TTS_FL_SRC="$HOME/git/.configs/tts-flutter"
TTS_FL_BIN="$TTS_FL_SRC/build/linux/x64/release/bundle/tts_client"
if [[ "$(conf_get headless no)" == yes ]]; then
  ok "tts flutter client: desktop-side, skipped on a headless host"
elif [[ "$(conf_get component_tts "$CFG_DEF")" != yes ]]; then
  ok "tts flutter client: not wanted (component_tts=no)"
elif [[ ! -d "$TTS_FL_SRC" ]]; then
  warn "tts flutter client: source missing ($TTS_FL_SRC) — run 06-configs"
elif [[ ! -x "$FLUTTER_BIN" ]]; then
  warn "tts flutter client: flutter SDK missing — run 05-flutter-android"
elif [[ -x "$TTS_FL_BIN" ]]; then
  ok "tts flutter client bundle present"
elif ! command -v cmake ninja clang pkg-config >/dev/null 2>&1; then
  # toolchain comes from the dev-flutter-deps apt group; without it flutter
  # prints "CMake is required" and the build is a 2-minute no-op per pass
  warn "tts flutter client: Linux build toolchain missing (cmake/ninja/clang/pkg-config — apt dev-flutter-deps) — build deferred"
elif (( INSTALL )); then
  warn "tts flutter client bundle not built — building"
  (cd "$TTS_FL_SRC" && "$FLUTTER_BIN" build linux --release) 2>&1 | extout
  [[ -x "$TTS_FL_BIN" ]] && ok "tts flutter client built" \
    || miss "tts: flutter build linux --release (bundle still absent)"
else
  warn "tts flutter client bundle not built (would: cd $TTS_FL_SRC && flutter build linux --release)"
fi

if [[ "$(conf_get component_emudhra no)" == yes ]]; then
  source "$KIT_DIR/components/emudhra.sh"
fi
