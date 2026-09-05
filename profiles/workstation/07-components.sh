#!/bin/bash
# Components: oom-zram/uutils-ls (default ON), docker, herdr/ollama/whisper (opt-in), dictation/ocr/tts.
# Specs live in components/*.md — keep behavior in sync with them.
SCRIPT_NAME="ws-07-components"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

# ------------------------------------------------------------- oom-zram
if [[ "$(conf_get component_oom_zram yes)" == yes ]]; then
  section "oom-zram ($MODE) — components/oom-zram.md"
  # zram size: min(ram/4, 8192) MB  (TODO from component doc: done here)
  RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  ZRAM_MB=$(( RAM_MB / 4 < 8192 ? RAM_MB / 4 : 8192 ))

  if dpkg -s systemd-zram-generator >/dev/null 2>&1; then
    ok "systemd-zram-generator installed"
  else
    warn "systemd-zram-generator missing"
    apt_install systemd-zram-generator
  fi
  # Reconcile by CONTENT, not just presence: the package ships its own
  # zram-generator.conf (a dpkg conffile), so the old "write only when missing"
  # left a package-default file in place and never restored our prio-100 tuning
  # (and, on 24.04, the differing default is what triggered the conffile prompt
  # that hung the run). Render what we want and write iff it differs. Pairs with
  # apt_install's --force-confold, which keeps THIS file across package upgrades.
  ZRAM_WANT=$(printf '[zram0]\nzram-size = %s\ncompression-algorithm = zstd\nswap-priority = 100\n' "$ZRAM_MB")
  if [[ -f /etc/systemd/zram-generator.conf && "$(cat /etc/systemd/zram-generator.conf)" == "$ZRAM_WANT" ]]; then
    ok "zram-generator.conf matches (${ZRAM_MB} MB zstd, prio 100)"
  else
    [[ -f /etc/systemd/zram-generator.conf ]] \
      && warn "zram-generator.conf drifted — reconciling to ${ZRAM_MB} MB zstd prio 100" \
      || warn "zram-generator.conf missing — writing ${ZRAM_MB} MB zstd prio 100"
    if (( INSTALL )); then
      printf '%s\n' "$ZRAM_WANT" | sudo tee /etc/systemd/zram-generator.conf >/dev/null
      sudo systemctl daemon-reload
      sudo systemctl restart systemd-zram-setup@zram0.service
    fi
  fi
  if [[ -f /etc/sysctl.d/99-zram.conf ]]; then
    ok "sysctl page-cluster tuned"
  else
    warn "vm.page-cluster not tuned for zram"
    if (( INSTALL )); then
      printf '# zram pairing: swap-ins are RAM reads, no readahead clustering\nvm.page-cluster = 0\n' \
        | sudo tee /etc/sysctl.d/99-zram.conf >/dev/null
      sudo sysctl --system >/dev/null
    fi
  fi
  if [[ -f /etc/systemd/oomd.conf.d/20-longer-duration.conf ]]; then
    ok "oomd pressure duration softened"
  else
    warn "oomd at trigger-happy defaults (50%/20s)"
    if (( INSTALL )); then
      sudo mkdir -p /etc/systemd/oomd.conf.d
      printf '[OOM]\nDefaultMemoryPressureDurationSec=60s\n' \
        | sudo tee /etc/systemd/oomd.conf.d/20-longer-duration.conf >/dev/null
      sudo systemctl restart systemd-oomd
      # live + persistent for THIS uid; does not restart the user session
      sudo systemctl set-property "user@$(id -u).service" ManagedOOMMemoryPressureLimit=80%
    fi
  fi
  # Swap policy: zram is always the first tier.
  #   auto      : RAM < 16G → zram + 4G disk overflow at prio -2 (emergency
  #               only — SSD writes only under genuine overcommit)
  #               RAM ≥ 16G → zram-only (no disk swap ever — SSD wear)
  #   zram-only | zram+disk : explicit override per host
  SWAP_POLICY="$(conf_get swap_policy auto)"
  if [[ "$SWAP_POLICY" == auto ]]; then
    (( RAM_MB < 16384 )) && SWAP_POLICY=zram+disk || SWAP_POLICY=zram-only
  fi
  DISK_SWAPS=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$1 !~ /zram/ {print $1}')
  if [[ "$SWAP_POLICY" == zram-only ]]; then
    if [[ -z "$DISK_SWAPS" ]] && ! grep -qE '^[^#].*\sswap\s' /etc/fstab; then
      ok "swap policy zram-only: no disk swap ✓"
    else
      warn "swap policy zram-only but disk swap present: ${DISK_SWAPS:-fstab entry}"
      if (( INSTALL )); then
        for s in $DISK_SWAPS; do
          sudo swapoff "$s" && log "swapoff: $s"
          case "$s" in /swap.img|/swapfile) sudo rm -f "$s" && log "removed $s" ;; esac
        done
        sudo sed -i.setup-kit.bak -E 's@^([^#].*\sswap\s.*)@# \1   # disabled by setup-kit (zram-only policy)@' /etc/fstab
        log "fstab swap entries commented (backup: /etc/fstab.setup-kit.bak)"
      fi
    fi
  else  # zram+disk
    if [[ -n "$DISK_SWAPS" ]]; then
      ok "swap policy zram+disk: overflow present (${DISK_SWAPS}, zram wins at prio 100)"
    else
      warn "swap policy zram+disk: no disk overflow tier (RAM ${RAM_MB}MB)"
      if (( INSTALL )); then
        sudo fallocate -l 4G /swap.img \
          && sudo chmod 600 /swap.img \
          && sudo mkswap /swap.img >/dev/null \
          && sudo swapon --priority -2 /swap.img \
          && log "created /swap.img 4G at prio -2 (emergency overflow)"
        grep -qE '^/swap\.img\s' /etc/fstab \
          || echo '/swap.img none swap sw,pri=-2 0 0' | sudo tee -a /etc/fstab >/dev/null
      fi
    fi
  fi

  # dbus shield is user-level config — belongs to .configs; doctor-check only
  if [[ -f "$HOME/.config/systemd/user/dbus.service.d/oomd-avoid.conf" ]]; then
    ok "dbus oomd shield present"
  else
    warn "dbus oomd shield missing (ManagedOOMPreference=avoid)"
    hint "belongs in .configs (user-level); without it oomd can kill dbus → force logout"
    if (( INSTALL )); then
      mkdir -p "$HOME/.config/systemd/user/dbus.service.d"
      printf '[Service]\nManagedOOMPreference=avoid\n' \
        > "$HOME/.config/systemd/user/dbus.service.d/oomd-avoid.conf"
      systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
fi

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

# ------------------------------------------------------------- dictation
# Speech-to-text chain (CPU-only — vosk lgraph model; NOT GPU-gated like
# TTS). .configs ships hotkeys + wrapper; this provisions what they call:
# the nerd-dictation repo, vosk in the pyenv python, and the model.
# Without it: the .configs Alt+s hotkey fires but the wrapper can't find vosk.
if [[ "$(conf_get component_dictation yes)" == yes ]]; then
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
    # enabled is not running: the package presets it enabled, but ydotoold
    # exits 2 until /dev/uinput (group input) is openable — i.e. after the
    # next login. Start it only when the group is effective; else say so.
    if systemctl --user is-active ydotool.service >/dev/null 2>&1; then ok "ydotoold running (ydotool.service)"
    elif pkg_installed ydotool; then
      if id -nG 2>/dev/null | grep -qw input; then
        warn "ydotool.service not running — starting ydotoold"
        do_or_say systemctl --user enable --now ydotool.service
      else
        warn "ydotoold can't start until the input group is effective — log out and back in"
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
if [[ "$(conf_get component_ocr yes)" == yes ]]; then
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
# torch). ALWAYS provisioned, NOT opt-in: .configs ships the clipboard-TTS
# client (now the Flutter control window, replacing the old Tk client) plus
# the server symlinks unconditionally, and the client is useless without this
# backend — so the venv is a baseline dependency. (Heavy; kokoro ~82M runs on
# GPU when torch can drive the card, else CPU — see the torch-backend note
# below.) Deps live in a DEDICATED pyenv virtualenv named
# `kokoro-tts` (~/.pyenv/versions/kokoro-tts), NOT pyenv global — so the
# .configs shebangs (#!~/.pyenv/versions/kokoro-tts/bin/python) resolve regardless
# of global (which stays system for a clean prompt), the deps don't pollute
# the bare 3.12, and the path is stable across machines (name, not patch).
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

# --------------------------------------------- tts flutter client bundle
# .configs ships the Flutter control-window SOURCE only; build/ is gitignored,
# so a fresh machine has no usable client binary until we compile it here. The
# ~/bin/tts-clipboard-flutter wrapper execs the bundle's tts_client. Needs the
# flutter SDK (05) and the .configs checkout (06), both of which precede us.
FLUTTER_BIN="$HOME/development/flutter/bin/flutter"
TTS_FL_SRC="$HOME/git/.configs/tts-flutter"
TTS_FL_BIN="$TTS_FL_SRC/build/linux/x64/release/bundle/tts_client"
if [[ ! -d "$TTS_FL_SRC" ]]; then
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
