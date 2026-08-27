#!/bin/bash
# PREFLIGHT — will what we are about to install actually FIT?
#
# Runs first (sorts ahead of 00-identity), before anything is downloaded or
# unpacked: projects the footprint of every wanted-but-missing thing and
# compares it against free space on the filesystem that will really hold it —
# per filesystem, because /home is often its own volume and a box with 400 GB
# free on / can still have 2 GB free where Android SDK lands.
#
# Running out of disk MID-install is the expensive failure: apt half-unpacks,
# dpkg needs manual repair, and the phase loop keeps retrying into a full disk.
# The check costs a few seconds; the failure costs an afternoon.
#
# Numbers come from two places, never mixed up in the report:
#   measured  — apt resolves the real transaction (deps included) and every
#               package's Installed-Size/download size comes from its own index
#   declared  — manifests/sizes.conf, for the things that publish no size until
#               you are already downloading them (SDK tarballs, model weights,
#               vendor .debs). Estimates, labelled as such.
#
# Policy: host conf `space_check` = enforce (default) | warn | no.
#   enforce — a shortfall exits 3, which stops the whole bootstrap run
#   warn    — report the shortfall, keep going
#   no      — skip the phase
SCRIPT_NAME="ws-00-disk-space"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "disk space preflight ($MODE)"

POLICY="$(conf_get space_check enforce)"
case "$POLICY" in
  no) ok "disk space preflight: off (space_check=no)"; exit 0 ;;
  enforce|warn) ;;
  *) warn "space_check='$POLICY' unrecognized — treating as enforce"; POLICY=enforce ;;
esac
HEADROOM_KB=$(to_kb "$(conf_get disk_headroom_gb 10)G")

# ---- declared sizes -------------------------------------------------------
SIZES_CONF="$MANIFEST_DIR/sizes.conf"
declare -A SZ_KB=() SZ_TGT=()
if [[ -r "$SIZES_CONF" ]]; then
  while read -r key size tgt _rest; do
    [[ -z "${key:-}" || "$key" == \#* ]] && continue
    SZ_KB["$key"]=$(to_kb "$size"); SZ_TGT["$key"]="${tgt:-ROOT}"
  done < <(sed 's/#.*//' "$SIZES_CONF")
else
  warn "no $SIZES_CONF — non-apt footprints can't be estimated"
fi

# Resolve a target token to a real path. ROOT/VAR/HOME keep the manifest free
# of this machine's layout; an absolute path passes through.
tgt_path() {
  case "$1" in
    ROOT) echo /usr ;;
    VAR)  echo /var ;;
    HOME) echo "$HOME" ;;
    /*)   echo "$1" ;;
    *)    echo / ;;
  esac
}
declared_kb()  { echo "${SZ_KB[$1]:-${SZ_KB[$2]:-0}}"; }
declared_tgt() { tgt_path "${SZ_TGT[$1]:-${SZ_TGT[$2]:-ROOT}}"; }

# ---- accumulator ----------------------------------------------------------
# One row per consumer; requirement summed per filesystem, since that — not
# the box's total free space — is what the install actually has to fit into.
ROWS=(); declare -A NEED=() MOUNT_FREE=()
add_need() {   # label  kb  path  kind(measured|declared)
  local label="$1" kb="$2" path="$3" kind="$4" mp free
  (( kb > 0 )) || return 0
  IFS=$'\t' read -r mp free < <(fs_stats "$path")
  [[ -n "${mp:-}" ]] || { warn "can't stat filesystem for $path — '$label' not counted"; return 0; }
  MOUNT_FREE["$mp"]="$free"
  NEED["$mp"]=$(( ${NEED[$mp]:-0} + kb ))
  ROWS+=("$label"$'\t'"$kb"$'\t'"$mp"$'\t'"$kind")
}

# ---- apt: measured --------------------------------------------------------
# Same wanted-list the installer uses (lib.sh apt_wanted_pkgs) — an estimate
# derived from a second copy of that logic would answer for a different set of
# packages than the one that installs. Notes dropped here; 02 replays them.
apt_want_into WANT quiet
APT_MISSING=()
for p in "${WANT[@]}"; do pkg_installed "$p" || APT_MISSING+=("$p"); done

if (( ${#APT_MISSING[@]} )); then
  # Prune names with no candidate FIRST: one of them makes the dry-run fail
  # outright, and a preflight that reports "apt: 0" because a single dropped
  # package name upset it is worse than no preflight at all.
  mapfile -t APT_SIM < <(apt_installable "${APT_MISSING[@]}")
  n_gone=$(( ${#APT_MISSING[@]} - ${#APT_SIM[@]} ))
  (( n_gone > 0 )) && ok "apt: $n_gone of ${#APT_MISSING[@]} wanted packages have no candidate on this release — not counted (02 logs them)"
  # -s needs no root and takes no lock, so this is safe in check mode too.
  if (( ${#APT_SIM[@]} )) && SIM_OUT="$(apt-get install -s --no-install-recommends "${APT_SIM[@]}" 2>/dev/null)"; then
    mapfile -t INST < <(awk '/^Inst /{print $2}' <<<"$SIM_OUT")
    if (( ${#INST[@]} )); then
      # Sum the index's own numbers rather than parsing "After this operation,
      # 18.4 MB…": that sentence is localized and unit-scaled, this is neither.
      # Installed-Size is KiB, Size (download) is bytes.
      read -r apt_kb apt_dl_kb < <(apt-cache --no-all-versions show "${INST[@]}" 2>/dev/null \
        | awk '/^Installed-Size:/{i+=$2} /^Size:/{d+=$2} END{printf "%d %d\n", i, d/1024}')
      add_need "apt: ${#INST[@]} packages (${#APT_SIM[@]} asked, rest are deps)" \
               "${apt_kb:-0}" /usr measured
      # Archives are downloaded in full before unpacking, so at the peak the
      # cache and the unpacked files coexist. Transient, but it has to fit.
      add_need "apt: .deb download cache (freed after install)" \
               "${apt_dl_kb:-0}" /var/cache/apt measured
    fi
  elif (( ${#APT_SIM[@]} )); then
    # Still no simulation (broken sources, held packages). Sum what the index
    # says about the asked-for packages alone — no dependency expansion, so a
    # guaranteed undercount, but a number with a stated shape beats silence.
    apt_kb=$(apt-cache --no-all-versions show "${APT_SIM[@]}" 2>/dev/null \
             | awk '/^Installed-Size:/{i+=$2} END{printf "%d\n", i}')
    warn "apt dry-run failed — falling back to a no-dependencies sum (UNDERCOUNT)"
    hint "the real transaction pulls in dependencies too; fix apt (apt-get update) for a true figure"
    add_need "apt: ${#APT_SIM[@]} packages, dependencies NOT counted" "${apt_kb:-0}" /usr declared
  fi
else
  ok "apt: all ${#WANT[@]} wanted packages already installed"
fi
add_need "apt: package index lists" "$(declared_kb apt_lists)" "$(declared_tgt apt_lists)" declared

# ---- snaps ----------------------------------------------------------------
# Live store size when snapd can answer (it's the download size, and snaps stay
# compressed on disk, so it doubles as the installed size); declared fallback
# when it can't — a fresh box may have no network yet.
snap_missing=0
while IFS= read -r entry; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"; [[ -z "$entry" ]] && continue
  grp=""
  if [[ "$entry" == *" @"* ]]; then grp="${entry##*@}"; entry="${entry% @*}"; fi
  name="${entry%% *}"
  [[ -n "$grp" ]] && ! group_on "$grp" && continue
  snap list "$name" >/dev/null 2>&1 && continue
  ((snap_missing++))
  kb=0
  if command -v snap >/dev/null 2>&1; then
    kb=$(to_kb "$(timeout 6 snap info "$name" 2>/dev/null \
                  | awk '$1 ~ /^latest\/stable:/ {print $(NF-1); exit}')")
  fi
  (( kb > 0 )) && kind=measured || { kb=$(declared_kb snap_default); kind=declared; }
  add_need "snap: $name" "$kb" "$(declared_tgt snap_default)" "$kind"
done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/snap.list" 2>/dev/null)
# Bases/runtimes (core*, gnome-*, mesa-*) are shared and charged once — only on
# a box that has none of them yet.
if (( snap_missing )) && ! snap list core24 >/dev/null 2>&1; then
  add_need "snap: shared bases/runtimes (core*, gnome-*, mesa-*)" \
           "$(declared_kb snap_bases)" "$(declared_tgt snap_bases)" declared
fi

# ---- flatpaks -------------------------------------------------------------
while IFS= read -r entry; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"; [[ -z "$entry" ]] && continue
  grp=""
  if [[ "$entry" == *" @"* ]]; then grp="${entry##*@}"; entry="${entry% @*}"; fi
  app="${entry%% *}"
  [[ -n "$grp" ]] && ! group_on "$grp" && continue
  flatpak info "$app" >/dev/null 2>&1 && continue
  add_need "flatpak: $app (+ runtime)" \
           "$(declared_kb flatpak_default)" "$(declared_tgt flatpak_default)" declared
done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/flatpak.list" 2>/dev/null)

# ---- vendor .debs ---------------------------------------------------------
while read -r name method arg grp _rest; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  [[ "$method" == manual ]] && continue          # doctor-warns only; never installed here
  [[ -n "${grp:-}" ]] && ! group_on "$grp" && continue
  pkg_installed "$name" && continue
  add_need "deb: $name" "$(declared_kb "deb_$name" deb_default)" \
           "$(declared_tgt "deb_$name" deb_default)" declared
done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/debs.list" 2>/dev/null)

# ---- language stacks ------------------------------------------------------
# want_new <conf-key> <default> <probe path or ''> — charge only for what the
# box doesn't already have.
want_new() {   # conf-key  default  [probe ...]   probe: a path, or cmd:<name>
  [[ "$(conf_get "$1" "$2")" == yes ]] || return 1
  local pr; shift 2
  for pr in "$@"; do
    case "$pr" in
      cmd:*) command -v "${pr#cmd:}" >/dev/null 2>&1 && return 1 ;;
      ?*)    [[ -e "$pr" ]] && return 1 ;;
    esac
  done
  return 0
}
want_new lang_python yes "$HOME/.pyenv/versions" && {
  add_need "python: pyenv + interpreter" "$(declared_kb lang_python)" "$(declared_tgt lang_python)" declared
  add_need "python: pipx tools"          "$(declared_kb lang_python_pipx)" "$(declared_tgt lang_python_pipx)" declared
}
want_new lang_node yes "$HOME/.nvm/versions/node" &&
  add_need "node: nvm + LTS + npm globals" "$(declared_kb lang_node)" "$(declared_tgt lang_node)" declared
want_new lang_flutter yes "$HOME/development/flutter" &&
  add_need "flutter: SDK + pub cache" "$(declared_kb lang_flutter)" "$(declared_tgt lang_flutter)" declared
want_new lang_flutter yes "$HOME/Android/Sdk" &&
  add_need "android: Studio + SDK + emulator + AVD" "$(declared_kb lang_android)" "$(declared_tgt lang_android)" declared
want_new group_dev_go no "$HOME/go" &&
  add_need "go: toolchain + module cache" "$(declared_kb lang_go)" "$(declared_tgt lang_go)" declared
want_new group_dev_rust no "$HOME/.cargo" &&
  add_need "rust: rustup + toolchain" "$(declared_kb lang_rust)" "$(declared_tgt lang_rust)" declared

# ---- components -----------------------------------------------------------
comp() {   # conf-key  default  label  [probe ...]
  local key="$1" def="$2" label="$3"; shift 3
  want_new "$key" "$def" "$@" || return 0
  add_need "$label" "$(declared_kb "$key")" "$(declared_tgt "$key")" declared
}
comp component_ollama    no  "ollama: runtime + $(conf_get ollama_model qwen3-coder:30b) weights" \
                             cmd:ollama /usr/local/bin/ollama
comp component_whisper   no  "whisper: venv + $(conf_get whisper_model large-v3) weights" \
                             "$HOME/.local/share/pipx/venvs/whisper-ctranslate2"
comp component_dictation yes "dictation: nerd-dictation + vosk model" "$HOME/.pyenv/versions/vosk"
comp component_ocr       yes "ocr: tesseract + language data"         cmd:tesseract
comp component_tts       yes "tts: kokoro venv + voices"              "$HOME/.pyenv/versions/kokoro-tts"
comp component_mtga      no  "mtga: Arena client (Arena's own installer downloads it)" \
                             "$HOME/.wine/drive_c/Program Files/Wizards of the Coast/MTGA"
comp component_herdr     no  "herdr: agent multiplexer"  cmd:herdr "$HOME/.local/bin/herdr"
comp component_claude_skills yes "claude skills: repo clones" "$HOME/.claude/skills"
[[ -d "$HOME/git/.configs" ]] ||
  add_need "dotfiles: .configs clone + its setup" "$(declared_kb configs_repo)" "$(declared_tgt configs_repo)" declared

# ---- report ---------------------------------------------------------------
if (( ${#ROWS[@]} == 0 )); then
  ok "nothing left to install — no new disk space needed"
  exit 0
fi
{ printf '\n  projected footprint (m=measured from apt, d=declared estimate)\n'
  for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r label kb mp kind <<<"$r"
    printf '    %-58s %7s  %s  → %s\n' "$label" "$(kb_human "$kb")" \
           "$([[ "$kind" == measured ]] && echo m || echo d)" "$mp"
  done
} | extout

shortfall=0
for mp in "${!NEED[@]}"; do
  need="${NEED[$mp]}"; free="${MOUNT_FREE[$mp]}"
  want=$(( need + HEADROOM_KB ))
  msg="$mp: need $(kb_human "$need") + $(kb_human "$HEADROOM_KB") headroom = $(kb_human "$want"), free $(kb_human "$free")"
  if (( want <= free )); then
    ok "$msg"
  else
    shortfall=1
    fail "$msg — SHORT BY $(kb_human $(( want - free )))"
    # Name the biggest consumers ON THIS filesystem. In quiet mode the table
    # above never reaches the terminal — only FAIL lines and their hints do —
    # and "you are short 12G" without "the Android SDK is 10G of it" leaves
    # the reader with nothing to act on.
    while IFS=$'\t' read -r label kb rmp _kind; do
      [[ "$rmp" == "$mp" ]] || continue
      hint "largest: $label — $(kb_human "$kb")"
    done < <(printf '%s\n' "${ROWS[@]}" | sort -t$'\t' -k2,2nr | head -20) | head -3
    hint "free space, shrink the install (./bootstrap.sh list, then flip groups off), or adjust disk_headroom_gb"
  fi
done

if (( ! shortfall )); then
  exit 0
fi
if [[ "$POLICY" == warn ]]; then
  warn "insufficient disk space — continuing anyway (space_check=warn)"
  exit 0
fi
# enforce. In check mode there is nothing to protect — the doctor's job is to
# report ALL the drift, and a preflight that ends the report early hides the
# rest of it. Only an install gets stopped.
if (( ! INSTALL )); then
  hint "doctor only — an install would stop here"
  exit 1
fi
# Stop before anything is downloaded. Exit 3 is the kit's "do not continue"
# code — bootstrap.sh aborts the phase loop on it, because every later phase
# would be writing into a disk it has been told won't hold them, and a disk
# that fills mid-dpkg needs hand repair.
fail "aborting before anything is installed (space_check=enforce)"
hint "set space_check=warn in $HOST_CONF to override"
exit 3
