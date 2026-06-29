#!/usr/bin/env bash
# INDEPENDENT verification — checks the system against the manifests using
# only traditional tools. Deliberately does NOT source lib.sh or reuse the
# installer's logic: a bug shared between installer and verifier would lie
# twice. Read-only except for one benign refresh: with sudo it runs `apt-get
# update` to test source health (refreshes /var/lib/apt/lists, installs
# nothing). Exit 0 = system matches manifests.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
CONF="hosts/$(hostname).conf"
PASS=0; FAILN=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS+1)); }
failv() { printf 'FAIL  %s\n' "$*"; FAILN=$((FAILN+1)); }

# -- tiny, independent conf reader ------------------------------------------
# trim edges only — list values (skip_pkgs) are space-separated inside
cv() { sed -n "s/^$1=\([^#]*\).*/\1/p" "$CONF" 2>/dev/null | tail -1 | sed 's/^ *//;s/ *$//'; }
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
# mirror installer: nvidia only when ubuntu-drivers backs the GPU (legacy cards skip)
if lspci 2>/dev/null | grep -qi nvidia \
   && ubuntu-drivers devices 2>/dev/null | grep -q 'nvidia-driver'; then
  FILES+=(manifests/apt/conditional/nvidia.list)
fi
if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "" || "$(systemd-detect-virt 2>/dev/null)" == none ]] \
   && ! dpkg -s proxmox-ve >/dev/null 2>&1; then
  FILES+=(manifests/apt/conditional/virtualbox.list)
fi
apt_missing=0; apt_total=0
# guard: with no groups enabled FILES is empty, and `grep` with no file args
# would block reading stdin — feed it nothing instead.
if (( ${#FILES[@]} > 0 )); then
  while IFS= read -r p; do
    [[ "$SKIPS" == *" $p "* ]] && continue
    apt-cache show "$p" >/dev/null 2>&1 || continue   # not in this release's archive
    apt_total=$((apt_total+1))
    st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)
    [[ "$st" == "install ok installed" ]] || { failv "apt: $p ($st)"; apt_missing=$((apt_missing+1)); }
  done < <(grep -hvE '^[[:space:]]*(#|$)' "${FILES[@]}" 2>/dev/null | awk '{print $1}' | sort -u)
fi
(( apt_missing == 0 )) && pass "apt: all $apt_total available manifest packages installed"

# -- 1b. nvidia driver actually driving the GPU --------------------------------
# Installed != working: a stale initramfs still loads nouveau early, the nvidia
# module can't bind, and persistenced/cdi-refresh restart-loop — which otherwise
# only surfaces as opaque calm-check noise (caught in the wild: GTX 1080,
# driver 580 built and installed, nvidia-smi dead).
if [[ " ${FILES[*]} " == *conditional/nvidia.list* ]]; then
  if nvidia-smi >/dev/null 2>&1; then
    pass "nvidia: driver answering (nvidia-smi)"
  elif grep -q '^nouveau ' /proc/modules; then
    # no grep -q on the pipe: early exit SIGPIPEs lsinitramfs and pipefail
    # turns a real match into rc 141
    if lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null \
         | grep 'nvidia-graphics-drivers\.conf' >/dev/null; then
      failv "nvidia: nouveau holds the GPU; initramfs has the blacklist — reboot pending"
    else
      failv "nvidia: nouveau holds the GPU — blacklist missing from initramfs; fix: sudo update-initramfs -u -k all && reboot"
    fi
  else
    failv "nvidia: nvidia-smi not answering and no GPU driver loaded (DKMS build failed? secure boot?)"
  fi
fi

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
# gnome extensions: only on a GNOME box (CLI present); enablement is login-
# dependent on Wayland, so verify presence (installed), not active state.
if command -v gnome-extensions >/dev/null 2>&1; then
  while IFS= read -r line; do
    line="${line%%#*}"; line=$(echo "$line" | xargs); [[ -z "$line" ]] && continue
    grp=""; [[ "$line" == *" @"* ]] && { grp="${line##*@}"; line="${line% @*}"; }
    uuid="${line%% *}"
    [[ -n "$grp" ]] && ! gon "$grp" && continue
    gnome-extensions list 2>/dev/null | grep -qxF "$uuid" \
      && pass "gnome-ext: $uuid" || failv "gnome-ext: $uuid (not installed)"
  done < manifests/gnome-extensions.list
fi

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
# tts venv is always provisioned (07-components): .configs ships the clipboard
# TTS client + server unconditionally, so this backend must exist — not opt-in.
TTS_PY="$HOME/.pyenv/versions/kokoro-tts/bin/python"
[[ -x "$TTS_PY" ]] && "$TTS_PY" -c 'import kokoro,soundfile,vlc' 2>/dev/null \
  && pass "tts venv: kokoro/soundfile/vlc importable" \
  || failv "tts venv missing or incomplete (~/.pyenv/versions/kokoro-tts)"
# tts flutter client: .configs ships source only (build/ gitignored); 07 builds
# the bundle the ~/bin/tts-clipboard-flutter wrapper execs. Source ≠ usable bin.
TTS_FL_BIN="$HOME/git/.configs/tts-flutter/build/linux/x64/release/bundle/tts_client"
[[ -x "$TTS_FL_BIN" ]] && pass "tts flutter client bundle built" \
  || failv "tts flutter client bundle missing (run: cd ~/git/.configs/tts-flutter && flutter build linux --release)"
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
# A stale real file in ~/bin silently shadows the .configs version (e.g. a
# stale copy with a dead-venv shebang masking the fixed .configs tool).
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
  # middle-click paste of the PRIMARY selection. 26.04's gschema default is
  # false; .configs/setup.sh forces it true. A false here = the override
  # didn't take (or got reset).
  [[ "$(gsettings get org.gnome.desktop.interface gtk-enable-primary-paste 2>/dev/null)" == true ]] \
    && pass "middle-click primary paste enabled" \
    || failv "middle-click primary paste disabled (gtk-enable-primary-paste != true)"
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

# -- 7. system calm — a fresh install should be QUIET --------------------------
# State checks above say "is everything there"; this says "is anything
# misbehaving": restart loops, journal spam, busy processes. Caught in the
# wild: nvidia-cdi-refresh.service restart-looping 1500+ times against a
# driver that didn't support the GPU.
SETTLE=0
[[ "${1:-}" == --settle ]] && SETTLE="${2:-30}"

# 7a. failed units
nf=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
(( nf == 0 )) && pass "calm: no failed systemd units" \
  || { failv "calm: $nf failed unit(s):"; systemctl --failed --no-legend --plain | sed 's/^/        /'
       systemctl --failed --no-legend --plain | grep -q not-found \
         && echo "        ('not-found' = unit was removed mid-failure; a tombstone —" \
         && echo "         sudo systemctl reset-failed clears it)"; }

# 7b. flapping units — restart counter is the loop detector ("activating"
# units never show in --failed while systemd is busy restarting them)
flap=$(systemctl show '*.service' --property=Id,NRestarts 2>/dev/null \
  | awk -v RS='' -F'\n' '{id="";n=0
      for(i=1;i<=NF;i++){p=index($i,"=");k=substr($i,1,p-1);v=substr($i,p+1)
        if(k=="Id")id=v; if(k=="NRestarts")n=v}
      if(n+0>5) print "        "id" ("n" restarts)"}')
[[ -z "$flap" ]] && pass "calm: no flapping services (NRestarts ≤ 5)" \
  || { failv "calm: restart-looping service(s):"; printf '%s\n' "$flap"; }

# 7c. units stuck activating right now
act=$(systemctl list-units --state=activating --no-legend --plain 2>/dev/null | awk '{print $1}')
[[ -z "$act" ]] && pass "calm: nothing stuck activating" \
  || { failv "calm: stuck activating:"; printf '%s\n' "$act" | sed 's/^/        /'; }

# 7d. journal noise — warnings+errors per 5 min, with top repeat offenders
JWMAX=$(cv calm_journal_warns); JWMAX=${JWMAX:-50}
jw=$(journalctl -p warning --since "-5 min" -o cat 2>/dev/null | wc -l)
if (( jw <= JWMAX )); then
  pass "calm: journal quiet ($jw warnings+ in 5 min, max $JWMAX)"
else
  failv "calm: journal noisy ($jw warnings+ in 5 min, max $JWMAX) — top repeats:"
  journalctl -p warning --since "-5 min" -o cat 2>/dev/null \
    | sort | uniq -c | sort -rn | head -3 | sed 's/^/        /'
fi

# 7e. coredumps in the last hour
if command -v coredumpctl >/dev/null 2>&1; then
  nc=$(coredumpctl list --since "-1 hour" --no-legend 2>/dev/null | wc -l)
  (( nc == 0 )) && pass "calm: no recent coredumps" \
    || failv "calm: $nc coredump(s) in the last hour (coredumpctl list)"
fi

# 7f/7g. load + churn — only with --settle N (needs a quiet sample window;
# pointless straight after an install while apt/snapd are still digesting)
if (( SETTLE > 0 )); then
  echo "    (settling ${SETTLE}s before load/churn sampling...)"
  sleep "$SETTLE"
  CORES=$(nproc)
  LMAX=$(cv calm_load_per_core); LMAX=${LMAX:-50}   # load1*100/cores
  l1=$(awk '{printf "%d", $1*100}' /proc/loadavg)
  (( l1 / CORES <= LMAX )) \
    && pass "calm: load $(awk '{print $1}' /proc/loadavg) on $CORES cores" \
    || { failv "calm: load high for idle: $(awk '{print $1}' /proc/loadavg) on $CORES cores — top consumers:"
         ps aux --sort=-%cpu | awk 'NR>1&&NR<6{printf "        %s%% %s\n",$3,$11}'; }
  # fork churn: kernel total-process counter, 5s apart. A respawn loop
  # (modprobe every second) shows here even when each child dies instantly.
  f0=$(awk '/^processes/{print $2}' /proc/stat); sleep 5
  f1=$(awk '/^processes/{print $2}' /proc/stat)
  rate=$(( (f1 - f0) / 5 ))
  FMAX=$(cv calm_fork_rate); FMAX=${FMAX:-20}
  (( rate <= FMAX )) && pass "calm: fork rate ${rate}/s (max $FMAX)" \
    || failv "calm: high fork churn ${rate}/s (max $FMAX) — something is respawning"
fi

echo "=== verify done: $PASS pass, $FAILN fail ==="
exit $(( FAILN > 0 ))
