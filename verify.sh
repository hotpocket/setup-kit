#!/usr/bin/env bash
# INDEPENDENT verification — checks the system against the manifests using
# only traditional tools. Deliberately does NOT source lib.sh or reuse the
# installer's logic: a bug shared between installer and verifier would lie
# twice. Read-only. Exit 0 = system matches manifests.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
CONF="hosts/$(hostname).conf"
PASS=0; FAILN=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS+1)); }
failv() { printf 'FAIL  %s\n' "$*"; FAILN=$((FAILN+1)); }

# -- tiny, independent conf reader ------------------------------------------
cv() { sed -n "s/^$1=\([^#]*\).*/\1/p" "$CONF" 2>/dev/null | tail -1 | tr -d ' '; }
gon() { [[ "$(cv "group_${1//-/_}")" == yes ]]; }

echo "=== independent verify: $(hostname) — $(date -Iseconds) ==="
[[ -f "$CONF" ]] || { echo "no $CONF — nothing to verify against"; exit 1; }

# -- 1. apt packages ----------------------------------------------------------
# wanted = enabled groups' manifests, minus skip_pkgs, minus release-unknowns
SKIPS=" $(cv skip_pkgs) "
declare -a FILES=()
for f in manifests/apt/*.list; do
  g=$(basename "$f" .list)
  [[ "$g" == dropped || "$g" == libs-review || "$g" == misc-review ]] && continue
  gon "$g" && FILES+=("$f")
done
for f in manifests/apt/optional/*.list; do
  gon "$(basename "$f" .list)" && FILES+=("$f")
done
# conditionals re-derived independently
if lspci 2>/dev/null | grep -qi nvidia; then FILES+=(manifests/apt/conditional/nvidia.list); fi
if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "" || "$(systemd-detect-virt 2>/dev/null)" == none ]] \
   && ! dpkg -s proxmox-ve >/dev/null 2>&1; then
  FILES+=(manifests/apt/conditional/virtualbox.list)
fi
apt_missing=0; apt_total=0
while IFS= read -r p; do
  [[ "$SKIPS" == *" $p "* ]] && continue
  apt-cache show "$p" >/dev/null 2>&1 || continue   # not in this release's archive
  apt_total=$((apt_total+1))
  st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)
  [[ "$st" == "install ok installed" ]] || { failv "apt: $p ($st)"; apt_missing=$((apt_missing+1)); }
done < <(grep -hvE '^[[:space:]]*(#|$)' "${FILES[@]}" 2>/dev/null | awk '{print $1}' | sort -u)
(( apt_missing == 0 )) && pass "apt: all $apt_total available manifest packages installed"

# -- 2. snaps / flatpaks ------------------------------------------------------
while IFS= read -r line; do
  line="${line%%#*}"; line=$(echo "$line" | xargs); [[ -z "$line" ]] && continue
  grp=""; [[ "$line" == *" @"* ]] && { grp="${line##*@}"; line="${line% @*}"; }
  name="${line%% *}"
  [[ -n "$grp" ]] && ! gon "$grp" && continue
  snap list "$name" >/dev/null 2>&1 && pass "snap: $name" || failv "snap: $name"
done < manifests/snap.list
while IFS= read -r line; do
  line="${line%%#*}"; line=$(echo "$line" | xargs); [[ -z "$line" ]] && continue
  grp=""; [[ "$line" == *" @"* ]] && { grp="${line##*@}"; line="${line% @*}"; }
  [[ -n "$grp" ]] && ! gon "$grp" && continue
  flatpak info "$line" >/dev/null 2>&1 && pass "flatpak: $line" || failv "flatpak: $line"
done < manifests/flatpak.list

# -- 3. direct debs (url/github methods only; honor optional group gate) ------
while IFS=$'\t' read -r name method arg grp; do
  [[ -z "$name" || "$name" == \#* || "$method" == manual ]] && continue
  [[ -n "$grp" ]] && ! gon "$grp" && continue
  dpkg -s "$name" >/dev/null 2>&1 && pass "deb: $name" || failv "deb: $name"
done < <(grep -v '^\s*#' manifests/debs.list 2>/dev/null)

# -- 4. languages — probe the actual binaries ---------------------------------
PYVER=$(grep -hvE '^\s*(#|$)' manifests/lang/python.list | grep -v '^pipx:' | head -1)
command -v python3 >/dev/null && pass "python: system python3 present ($(python3 --version 2>&1))" \
  || failv "python: no system python3"
if [[ -x "$HOME/.pyenv/bin/pyenv" ]]; then
  got=$(PYENV_ROOT="$HOME/.pyenv" "$HOME/.pyenv/bin/pyenv" global 2>/dev/null | head -1)
  # policy: global stays system (clean prompt — version only shows in projects
  # with a .python-version). 3.12 is installed as an available version.
  [[ "$got" == system ]] && pass "python: pyenv global = system" \
    || failv "python: pyenv global is '$got' (policy: system, for a quiet prompt)"
  PYENV_ROOT="$HOME/.pyenv" "$HOME/.pyenv/bin/pyenv" versions --bare 2>/dev/null \
    | grep -E "^${PYVER}(\.|$)" | grep -qv / && pass "python: $PYVER available for projects" \
    || failv "python: $PYVER not installed"
else failv "python: pyenv missing"; fi
# audio-tool venvs — deps isolated in dedicated venvs, not in global/bare 3.12
if [[ "$(cv component_tts)" == yes ]]; then
  TTS_PY="$HOME/.pyenv/versions/kokoro-tts/bin/python"
  [[ -x "$TTS_PY" ]] && "$TTS_PY" -c 'import kokoro,soundfile,vlc' 2>/dev/null \
    && pass "tts venv: kokoro/soundfile/vlc importable" \
    || failv "tts venv missing or incomplete (~/.pyenv/versions/kokoro-tts)"
fi
if [[ "$(cv component_dictation)" == yes || -z "$(cv component_dictation)" ]]; then
  VOSK_PY="$HOME/.pyenv/versions/vosk/bin/python"
  [[ -x "$VOSK_PY" ]] && "$VOSK_PY" -c 'import vosk' 2>/dev/null \
    && pass "vosk venv: vosk importable (dictation)" \
    || failv "vosk venv missing (~/.pyenv/versions/vosk) — dictation may use a stray interpreter"
fi
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  v=$(bash -c 'source ~/.nvm/nvm.sh >/dev/null 2>&1; node --version' 2>/dev/null)
  [[ -n "$v" ]] && pass "node: $v via nvm" || failv "node: nvm present but node unusable"
else failv "node: nvm missing"; fi
java -version >/dev/null 2>&1 && pass "java: $(java -version 2>&1 | head -1)" || failv "java missing"
command -v mvn >/dev/null && pass "maven present" || failv "maven missing"
[[ -x "$HOME/development/flutter/bin/flutter" ]] && pass "flutter SDK present" || failv "flutter missing"
if command -v docker >/dev/null; then
  DMODE=$(cv component_docker_rootless); DMODE=${DMODE:-yes}
  if docker info 2>/dev/null | grep -qi rootless; then
    [[ "$DMODE" == yes ]] && pass "docker rootless (as configured)" \
      || failv "docker rootless but host conf says rootful"
  else
    [[ "$DMODE" == no ]] && pass "docker rootful (as configured)" \
      || failv "docker NOT rootless (host conf wants rootless)"
  fi
else failv "docker missing"; fi
command -v gcloud >/dev/null && pass "gcloud present" || failv "gcloud missing"
command -v aws >/dev/null && pass "aws present" || failv "aws missing"
command -v gh >/dev/null && pass "gh present" || failv "gh missing"
command -v shellcheck >/dev/null && pass "shellcheck present" || failv "shellcheck missing"

# -- 4b. dotfiles actually wired (not just cloned) ------------------------------
for df in .bashrc .bash_aliases .gitconfig; do
  if [[ -L "$HOME/$df" ]] && readlink -f "$HOME/$df" | grep -q "/.configs/"; then
    pass "dotfile: $df → .configs"
  else
    failv "dotfile: $df not symlinked into .configs"
  fi
done

# -- 4c. launcher assets (custom-tool icons resolve) ---------------------------
if [[ -d "$HOME/git/.configs/.local/share/icons" ]]; then
  for d in "$HOME"/git/.configs/.local/share/applications/*.desktop; do
    [[ -f "$d" ]] || continue
    icon=$(sed -n 's/^Icon=//p' "$d" | head -1)
    [[ "$icon" == /* ]] && continue   # absolute-path icons resolve trivially
    if find "$HOME/.local/share/icons" -name "$icon.*" 2>/dev/null | grep -q .; then
      pass "launcher icon: $icon"
    else
      failv "launcher icon missing: $icon (from $(basename "$d"))"
    fi
  done
  # a degenerate per-user hicolor cache (no index.theme) hides icons GTK
  # would otherwise find — flag it
  if [[ -f "$HOME/.local/share/icons/hicolor/icon-theme.cache" \
        && ! -f "$HOME/.local/share/icons/hicolor/index.theme" ]]; then
    failv "degenerate hicolor icon-theme.cache (no index.theme) — rm it"
  else
    pass "no degenerate icon cache"
  fi
fi

# -- 4d. ~/bin wiring — every .configs tool must be the LIVE symlink ------------
# A stale real file in ~/bin silently shadows the .configs version (this hid
# broken tts scripts with a dead-venv shebang on LeBuntu 2026-06-06).
bin_bad=0; bin_n=0
while IFS= read -r tool; do
  n="$(basename "$tool")"; tgt="$HOME/bin/$n"; bin_n=$((bin_n+1))
  if [[ -L "$tgt" && "$(readlink -f "$tgt")" == "$(readlink -f "$tool")" ]]; then
    :
  elif [[ -e "$tgt" && ! -L "$tgt" ]]; then
    failv "bin: ~/bin/$n is a REAL FILE shadowing .configs/bin (stale copy?)"; bin_bad=$((bin_bad+1))
  else
    failv "bin: ~/bin/$n not linked to .configs/bin"; bin_bad=$((bin_bad+1))
  fi
done < <(find "$HOME/git/.configs/bin" -maxdepth 1 -type f -executable 2>/dev/null)
(( bin_bad == 0 && bin_n > 0 )) && pass "bin: all $bin_n .configs tools live-linked"

# -- 4e. autostart entries wired ------------------------------------------------
for src in "$HOME"/git/.configs/.config/autostart/*.desktop; do
  [[ -f "$src" ]] || continue
  n="$(basename "$src")"
  # entries whose Exec binary isn't on this box are intentionally unwired
  exe="$(sed -n 's/^Exec=//p' "$src" | head -1 | tr -d '"' | awk '{print $1}')"
  if [[ -n "$exe" ]] && ! command -v "$exe" >/dev/null 2>&1 && [[ ! -x "$exe" ]]; then
    pass "autostart: $n n/a here ($exe not installed)"
    continue
  fi
  if [[ -e "$HOME/.config/autostart/$n" ]]; then
    pass "autostart: $n"
  else
    failv "autostart: $n not wired into ~/.config/autostart"
  fi
done

# -- 4f. dock pins (only meaningful inside a session) ---------------------------
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v gsettings >/dev/null; then
  favs="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"
  for d in "$HOME"/git/.configs/.local/share/applications/*.desktop; do
    [[ -f "$d" ]] || continue
    n="$(basename "$d")"
    [[ "$favs" == *"'$n'"* ]] && pass "dock pin: $n" || failv "dock pin: $n not in favorites"
  done
fi

# -- 5. oom-zram component — kernel-level truth --------------------------------
swapon --show=NAME,PRIO --noheadings 2>/dev/null | grep -q 'zram.*100' \
  && pass "zram swap active at prio 100" || failv "zram swap not active"
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
POLICY=$(cv swap_policy); [[ -z "$POLICY" || "$POLICY" == auto ]] \
  && { (( RAM_MB < 16384 )) && POLICY=zram+disk || POLICY=zram-only; }
DISK=$(swapon --show=NAME --noheadings 2>/dev/null | grep -v zram || true)
if [[ "$POLICY" == zram+disk ]]; then
  [[ -n "$DISK" ]] && pass "swap policy $POLICY: overflow $DISK" || failv "swap policy $POLICY: no overflow"
else
  [[ -z "$DISK" ]] && pass "swap policy $POLICY: no disk swap" || failv "swap policy $POLICY: disk swap present: $DISK"
fi
[[ "$(sysctl -n vm.page-cluster 2>/dev/null)" == 0 ]] && pass "vm.page-cluster=0" || failv "vm.page-cluster != 0"
[[ -f /etc/systemd/oomd.conf.d/20-longer-duration.conf ]] && pass "oomd softened" || failv "oomd conf missing"
[[ -f "$HOME/.config/systemd/user/dbus.service.d/oomd-avoid.conf" ]] && pass "dbus oomd shield" || failv "dbus shield missing"

# -- 6. apt health (update needs root; fall back to read-only consistency) ----
if sudo -n true 2>/dev/null; then
  errs=$(sudo -n apt-get update 2>&1 | grep -cE '^(E:|Err)' || true)
  [[ "$errs" == 0 ]] && pass "apt sources healthy (apt-get update: 0 errors)" \
    || failv "apt-get update has $errs errors"
else
  # no sudo: apt-get check needs the lock — dpkg --audit doesn't and
  # reports broken/half-configured packages (empty output = healthy)
  if [[ -z "$(dpkg --audit 2>/dev/null)" ]]; then
    pass "dpkg consistent (dpkg --audit clean; apt update skipped — no sudo)"
  else
    failv "dpkg --audit reports broken packages"
  fi
fi

echo "=== verify done: $PASS pass, $FAILN fail ==="
exit $(( FAILN > 0 ))
