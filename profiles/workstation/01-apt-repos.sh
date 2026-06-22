#!/bin/bash
# Third-party apt repos — only for enabled groups (see manifests/apt/repos.md).
# Keys fetched fresh from vendors (never from snapshot); signed-by always.
SCRIPT_NAME="ws-01-apt-repos"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
ARCH="$(dpkg --print-architecture)"
KEYDIR=/etc/apt/keyrings
NEED_UPDATE=0

# repo <group> <name> <key-url> <line>   (line may reference $KEYDIR/$name.gpg)
repo() {
  local group="$1" name="$2" keyurl="$3" line="$4"
  local listfile="/etc/apt/sources.list.d/${name}.list"
  if [[ "$group" != always ]] && ! group_on "$group"; then
    return 0
  fi
  if [[ -e "$listfile" ]] || grep -rqs "${name}" /etc/apt/sources.list.d/ 2>/dev/null; then
    ok "repo $name present"
    return 0
  fi
  warn "repo $name missing (group: $group)"
  if (( INSTALL )); then
    sudo mkdir -p "$KEYDIR"
    if [[ -n "$keyurl" ]]; then
      curl -fsSL "$keyurl" | gpg --dearmor | sudo tee "$KEYDIR/${name}.gpg" >/dev/null \
        || { miss "repo key: $name ($keyurl)"; return 1; }
      sudo chmod 644 "$KEYDIR/${name}.gpg"
    fi
    echo "$line" | sudo tee "$listfile" >/dev/null
    log "added repo: $name"
    NEED_UPDATE=1
  else
    hint "$line"
  fi
}

ppa() {  # ppa <group> <ppa:user/name>
  local group="$1" p="$2" slug
  slug="${p#ppa:}"; slug="${slug//\//-ubuntu-}"
  if [[ "$group" != always ]] && ! group_on "$group"; then return 0; fi
  if ls /etc/apt/sources.list.d/ 2>/dev/null | grep -q "^${slug}"; then
    ok "ppa $p present"
  else
    warn "ppa $p missing (group: $group)"
    do_or_say sudo add-apt-repository -y --no-update "$p" && NEED_UPDATE=1
  fi
}

section "apt repos ($MODE) — $CODENAME/$ARCH"

repo dev_core docker \
  "https://download.docker.com/linux/ubuntu/gpg" \
  "deb [arch=$ARCH signed-by=$KEYDIR/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable"
repo dev_core ddev \
  "https://pkg.ddev.com/apt/gpg.key" \
  "deb [signed-by=$KEYDIR/ddev.gpg] https://pkg.ddev.com/apt/ * *"
repo dev_cloud google-cloud-sdk \
  "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
  "deb [signed-by=$KEYDIR/google-cloud-sdk.gpg] https://packages.cloud.google.com/apt cloud-sdk main"
# NO vscode repo here — the `code` package manages its own source file
# (/etc/apt/sources.list.d/vscode.sources, signed-by /usr/share/keyrings/microsoft.gpg).
# Adding our own vscode.list pointed at a *different* signed-by path breaks ALL of
# apt with a Signed-By conflict — apt compares the keyring PATHS, not the keys, so
# even the byte-identical Microsoft key in two locations is fatal. Same trap as steam.
# Heal boxes that got the bad list from an earlier setup-kit run:
if [[ -e /etc/apt/sources.list.d/vscode.list ]]; then
  warn "removing stale vscode.list (conflicts with the code package's vscode.sources)"
  do_or_say sudo rm -f /etc/apt/sources.list.d/vscode.list && NEED_UPDATE=1
fi
repo apps google-chrome \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "deb [arch=$ARCH signed-by=$KEYDIR/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main"
repo apps brave-browser \
  "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" \
  "deb [arch=$ARCH signed-by=$KEYDIR/brave-browser.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"
repo wine winehq \
  "https://dl.winehq.org/wine-builds/winehq.key" \
  "deb [signed-by=$KEYDIR/winehq.gpg] https://dl.winehq.org/wine-builds/ubuntu/ $CODENAME main"
# NO steam repo here — the steam package manages its own sources files
# (/etc/apt/sources.list.d/steam-stable.list, /usr/share/keyrings/steam.gpg).
# Adding our own breaks all of apt with a Signed-By conflict.
repo cli_system charm \
  "https://repo.charm.sh/apt/gpg.key" \
  "deb [signed-by=$KEYDIR/charm.gpg] https://repo.charm.sh/apt/ * *"

ppa media  ppa:obsproject/obs-studio
ppa media  ppa:marin-m/songrec
ppa apps   ppa:alessandro-strada/ppa
ppa games  ppa:minetestdevs/stable

# conditional: nvidia container toolkit (docker GPU) only with a SUPPORTED card
if nvidia_wanted && group_on dev_core; then
  repo always nvidia-container-toolkit \
    "https://nvidia.github.io/libnvidia-container/gpgkey" \
    "deb [signed-by=$KEYDIR/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /"
fi

# games need i386 (steam)
if group_on games; then
  if dpkg --print-foreign-architectures | grep -qx i386; then
    ok "i386 foreign arch enabled (steam)"
  else
    warn "i386 arch missing (steam needs it)"
    do_or_say sudo dpkg --add-architecture i386 && NEED_UPDATE=1
  fi
fi

if (( INSTALL )) && (( NEED_UPDATE )); then
  log "apt update after repo changes..."
  sudo apt-get update 2>&1 | grep -E '^(Err|W:)' | tee -a "$LOG_DIR/apt-update-errors.log" || true
fi
