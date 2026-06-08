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
    if [[ -d "$SDK_DIR/$p" ]]; then
      ok "sdk: $p"
    else
      warn "sdk: $p missing"
      do_or_say "$CMDLINE/sdkmanager" "$p" || miss "android-sdk: $p"
    fi
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
  if [[ -d "$HOME/.android/avd" ]] && ls "$HOME/.android/avd"/*.avd >/dev/null 2>&1; then
    ok "AVD(s) defined: $(ls -d "$HOME/.android/avd"/*.avd 2>/dev/null | wc -l)"
  else
    warn "no AVDs — create one in Studio (Device Manager) after first launch"
  fi
else
  warn "android cmdline-tools missing"
  hint "first Studio launch installs the SDK; or unzip cmdline-tools into $SDK_DIR/cmdline-tools/latest"
fi

if [[ -x "$FLUTTER_DIR/bin/flutter" ]] && (( ! INSTALL )); then
  section "flutter doctor (informational)"
  "$FLUTTER_DIR/bin/flutter" doctor 2>/dev/null | sed 's/^/  /' || true
fi
