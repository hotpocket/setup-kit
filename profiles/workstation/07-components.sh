#!/bin/bash
# Components: oom-zram (default ON), docker, herdr (opt-in), dictation/ocr/tts.
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
    do_or_say sudo apt-get install -y systemd-zram-generator
  fi
  if [[ -f /etc/systemd/zram-generator.conf ]]; then
    ok "zram-generator.conf present ($(grep -oP 'zram-size = \K\S+' /etc/systemd/zram-generator.conf 2>/dev/null || echo '?') MB)"
  else
    warn "zram-generator.conf missing (would set ${ZRAM_MB} MB zstd)"
    if (( INSTALL )); then
      printf '[zram0]\nzram-size = %s\ncompression-algorithm = zstd\nswap-priority = 100\n' "$ZRAM_MB" \
        | sudo tee /etc/systemd/zram-generator.conf >/dev/null
      sudo systemctl daemon-reload
      sudo systemctl start systemd-zram-setup@zram0.service
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
  if [[ "${XDG_SESSION_TYPE:-}" == wayland ]] && ! command -v ydotool wtype >/dev/null 2>&1; then
    warn "Wayland session without ydotool/wtype — dictation can listen but can't type"
    hint "apt install ydotool (plus uinput perms) or switch the session to Xorg"
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
    else warn "ocr dep $d missing"; do_or_say sudo apt-get install -y "$d"; fi
  done
fi

# ------------------------------------------------------------- tts (kokoro)
# Clipboard TTS server (kokoro neural TTS + vlc + soundfile, HEAVY — pulls
# torch). ALWAYS provisioned, NOT opt-in: .configs ships the clipboard-TTS
# client (now the Flutter control window, replacing the old Tk client) plus
# the server symlinks unconditionally, and the client is useless without this
# backend — so the venv is a baseline dependency. (Heavy but CPU-fine; kokoro
# ~82M, no GPU gate.) Deps live in a DEDICATED pyenv virtualenv named
# `kokoro-tts` (~/.pyenv/versions/kokoro-tts), NOT pyenv global — so the
# .configs shebangs (#!~/.pyenv/versions/kokoro-tts/bin/python) resolve regardless
# of global (which stays system for a clean prompt), the deps don't pollute
# the bare 3.12, and the path is stable across machines (name, not patch).
section "tts (kokoro) ($MODE)"
for d in libsndfile1 vlc espeak-ng python3-tk; do
  pkg_installed "$d" && ok "tts dep $d" || { warn "tts dep $d missing"; do_or_say sudo apt-get install -y "$d"; }
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
  if "$TTS_PY" -c 'import kokoro,soundfile,vlc,tkinter' 2>/dev/null; then
    ok "tts venv deps (kokoro, soundfile, vlc, tkinter) present"
  else
    warn "tts venv deps missing"
    do_or_say "$TTS_PY" -m pip install --quiet kokoro soundfile python-vlc \
      || miss "tts: pip install into tts venv"
  fi
fi
