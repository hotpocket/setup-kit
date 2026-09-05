#!/bin/bash
# Flutter SDK + Android Studio + SDK + emulator (+ /dev/kvm doctor check).
# Full Android Studio (emulator wanted), default AVD.
SCRIPT_NAME="ws-05-flutter-android"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

[[ "$(conf_get lang_flutter yes)" == yes ]] || { ok "flutter: off in host conf"; exit 0; }

FLUTTER_DIR="$HOME/development/flutter"
STUDIO_DIR="$HOME/android-studio"
SDK_DIR="$HOME/Android/Sdk"
CMDLINE="$SDK_DIR/cmdline-tools/latest/bin"

section "/dev/kvm — emulator acceleration ($MODE)"
if has_kvm_dev; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "/dev/kvm present and accessible"
  else
    warn "/dev/kvm present but not accessible (kvm group? log out/in)"
    hint "00-identity adds you to the kvm group once it exists"
  fi
else
  case "$(virt_context)" in
    kvm)  fail "/dev/kvm missing in this VM — Proxmox host needs nested virt"
          hint "host: profiles/proxmox-host/05-nested-virt.sh + qm set <vmid> --cpu host" ;;
    lxc)  fail "/dev/kvm missing in this LXC — pass the device through"
          hint "host: dev0: /dev/kvm,gid=<kvm-gid> in /etc/pve/lxc/<ctid>.conf" ;;
    none) fail "/dev/kvm missing on bare metal — enable virtualization in BIOS" ;;
    *)    fail "/dev/kvm missing (virt: $(virt_context))" ;;
  esac
  hint "emulator will fall back to unusably-slow software rendering"
fi

section "flutter SDK ($MODE)"
if [[ -x "$FLUTTER_DIR/bin/flutter" ]]; then
  ok "flutter at $FLUTTER_DIR"
else
  warn "flutter SDK missing"
  do_or_say mkdir -p "$(dirname "$FLUTTER_DIR")"
  do_or_say git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
if [[ -x "$FLUTTER_DIR/bin/dart" ]]; then
  while IFS= read -r entry; do
    [[ "$entry" == dart-global:* ]] || continue
    pkg="${entry#dart-global:}"
    if "$FLUTTER_DIR/bin/dart" pub global list 2>/dev/null | grep "^$pkg " >/dev/null; then
      ok "dart global $pkg"
    else
      warn "dart global $pkg missing"
      do_or_say "$FLUTTER_DIR/bin/dart" pub global activate "$pkg" || miss "dart-global: $pkg"
    fi
  done < <(manifest_pkgs "$MANIFEST_DIR/lang/flutter.list")
fi

section "android studio ($MODE)"
if [[ -x "$STUDIO_DIR/bin/studio.sh" || -x "$STUDIO_DIR/bin/studio" ]]; then
  ok "android studio at $STUDIO_DIR (tarball — managed by hand, left alone)"
elif snap list android-studio >/dev/null 2>&1; then
  ok "android studio (snap)"
else
  warn "android studio missing"
  # The download page is JS-rendered (URL scraping fails); the snap is the
  # reliable scripted path.
  do_or_say sudo snap install android-studio --classic \
    || miss "android-studio: snap install failed — manual tarball from developer.android.com/studio"
fi

section "android SDK + emulator ($MODE)"
if [[ -x "$CMDLINE/sdkmanager" ]]; then
  ok "cmdline-tools present"
  for p in platform-tools emulator; do
    [[ -d "$SDK_DIR/$p" ]] && ok "sdk: $p" || warn "sdk: $p missing (installed below from flutter.list)"
  done
  if ls "$SDK_DIR/system-images" >/dev/null 2>&1; then
    ok "system image(s) present"
  else
    warn "no emulator system images"
    hint "install via Studio's SDK Manager, or: sdkmanager 'system-images;android-36;google_apis;x86_64'"
  fi
  # SDK licenses — must be pre-accepted or every sdkmanager/gradle build
  # stops at an interactive [y/N] wall. 'yes |' answers them all.
  if ls "$SDK_DIR/licenses/"android-sdk-license* >/dev/null 2>&1; then
    ok "android SDK licenses accepted"
  else
    warn "android SDK licenses not accepted"
    do_or_say bash -c "yes | '$CMDLINE/sdkmanager' --licenses >/dev/null" \
      || miss "android: sdkmanager --licenses failed"
  fi
  # one default AVD (flutter.list android-avd: row) on the newest installed
  # x86_64 google_apis image and the newest plain pixel_N profile. 'echo no'
  # answers avdmanager's custom-hardware-profile prompt.
  AVD_NAME="$(manifest_pkgs "$MANIFEST_DIR/lang/flutter.list" | grep -m1 '^android-avd:' | cut -d: -f2)"
  if [[ -d "$HOME/.android/avd" ]] && ls "$HOME/.android/avd"/*.avd >/dev/null 2>&1; then
    ok "AVD(s) defined: $(ls -d "$HOME/.android/avd"/*.avd 2>/dev/null | wc -l)"
  elif [[ -z "$AVD_NAME" ]]; then
    ok "no default AVD requested (flutter.list)"
  else
    IMG="$(ls -d "$SDK_DIR"/system-images/android-*/google_apis/x86_64 2>/dev/null | sort -V | tail -1)"
    if [[ -z "$IMG" ]]; then
      warn "no AVD yet — needs a system image first (installed above on the next pass)"
    else
      IMG="system-images;$(basename "$(dirname "$(dirname "$IMG")")");google_apis;x86_64"
      DEV="$("$CMDLINE/avdmanager" list device -c 2>/dev/null | grep -E '^pixel_[0-9]+$' | sort -V | tail -1)"
      warn "no AVDs — creating '$AVD_NAME' ($IMG, ${DEV:-pixel})"
      do_or_say bash -c "echo no | '$CMDLINE/avdmanager' create avd -n '$AVD_NAME' -k '$IMG' -d '${DEV:-pixel}' >/dev/null" \
        || miss "android-avd: $AVD_NAME ($IMG)"
    fi
  fi
else
  # Google publishes cmdline-tools at a version-numbered URL; the studio page
  # carries the current one. Unzip lands as cmdline-tools/, sdkmanager wants
  # cmdline-tools/latest/ — move it. Then licenses + the SDK pieces flutter
  # doctor asks for, all from manifests/lang/flutter.list (android-sdk: rows).
  warn "android cmdline-tools missing — installing (sdkmanager, licenses, SDK packages)"
  if (( INSTALL )); then
    CT_URL="$(curl -fsSL https://developer.android.com/studio 2>/dev/null \
              | grep -oE 'https://dl\.google\.com/android/repository/commandlinetools-linux-[0-9]+_latest\.zip' | head -1)"
    if [[ -z "$CT_URL" ]]; then
      miss "android-sdk: could not find the cmdline-tools download URL on developer.android.com/studio"
    else
      tmp="$(mktemp -d)"
      if curl -fsSL "$CT_URL" -o "$tmp/ct.zip" && unzip -q "$tmp/ct.zip" -d "$tmp" \
         && mkdir -p "$SDK_DIR/cmdline-tools" && rm -rf "$SDK_DIR/cmdline-tools/latest" \
         && mv "$tmp/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"; then
        log "installed cmdline-tools → $SDK_DIR/cmdline-tools/latest"
      else
        miss "android-sdk: cmdline-tools download/unpack failed ($CT_URL)"
      fi
      rm -rf "$tmp"
    fi
  else
    printf '  %s[would]%s download cmdline-tools → %s/cmdline-tools/latest, accept licenses, sdkmanager the flutter.list packages\n' "$C_DIM" "$C_RST" "$SDK_DIR"
  fi
fi
if [[ -x "$CMDLINE/sdkmanager" ]] && (( INSTALL )); then
  # licenses first (every sdkmanager install refuses without them), then the
  # manifest rows: 'latest' / 'current-stable' resolve against sdkmanager --list
  yes 2>/dev/null | "$CMDLINE/sdkmanager" --licenses >/dev/null 2>&1 || true
  SDK_LIST="$("$CMDLINE/sdkmanager" --list 2>/dev/null)"
  while IFS= read -r entry; do
    [[ "$entry" == android-sdk:* ]] || continue
    pkg="${entry#android-sdk:}"
    pkg="$(android_sdk_resolve "$pkg" <<<"$SDK_LIST")"
    [[ -n "$pkg" ]] || { miss "android-sdk: could not resolve '$entry' against sdkmanager --list"; continue; }
    [[ "$pkg" == system-images\;* ]] && SYS_IMG="$pkg"
    if grep -qE "^  ${pkg}[[:space:]]" <<<"$(sed -n '/^Installed packages:/,/^Available Packages:/p' <<<"$SDK_LIST")"; then
      ok "sdk: $pkg"
    else
      warn "sdk: $pkg missing"
      do_or_say "$CMDLINE/sdkmanager" "$pkg" >/dev/null || miss "android-sdk: $pkg"
    fi
  done < <(manifest_pkgs "$MANIFEST_DIR/lang/flutter.list")
  [[ -x "$FLUTTER_DIR/bin/flutter" ]] && { "$FLUTTER_DIR/bin/flutter" config --android-sdk "$SDK_DIR" >/dev/null 2>&1
                                          yes 2>/dev/null | "$FLUTTER_DIR/bin/flutter" doctor --android-licenses >/dev/null 2>&1 || true; }
fi

if [[ -x "$FLUTTER_DIR/bin/flutter" ]] && (( ! INSTALL )); then
  section "flutter doctor (informational)"
  "$FLUTTER_DIR/bin/flutter" doctor 2>/dev/null | sed 's/^/  /' | extout || true
fi
