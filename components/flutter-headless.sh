#!/bin/bash
source "$KIT_DIR/components/tool-common.sh"
section "flutter headless ($MODE) — components/flutter-headless.md"
FLUTTER_DIR="$HOME/development/flutter"
SDK_DIR="$HOME/Android/Sdk"
JAVA_DIR="$TOOL_ROOT/usr/lib/jvm/java-21-openjdk-amd64"
export ANDROID_HOME="$SDK_DIR" ANDROID_SDK_ROOT="$SDK_DIR" JAVA_HOME="$JAVA_DIR"
export PATH="$FLUTTER_DIR/bin:$JAVA_DIR/bin:$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:$PATH"
flutter_clone() (
  tool_x64 flutter || exit 1
  mkdir -p "$(dirname "$FLUTTER_DIR")" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$(dirname "$FLUTTER_DIR")" flutter "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$stage/flutter" \
    && [[ "$(git -C "$stage/flutter" rev-parse HEAD)" == "$FLUTTER_REVISION" ]] \
    && mv -T "$stage/flutter" "$FLUTTER_DIR"
)
flutter_dart_ready() {
  [[ -x "$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart" \
    && "$(cat "$FLUTTER_DIR/bin/cache/dart-sdk/.setup-kit-sha256" 2>/dev/null)" == "$FLUTTER_DART_SHA256" \
    && "$(cat "$FLUTTER_DIR/bin/cache/engine-dart-sdk.stamp" 2>/dev/null)" == "$FLUTTER_ENGINE_REVISION" ]] && tool_content_valid "$FLUTTER_DIR/bin/cache/dart-sdk" bin/dart
}
flutter_dart_install() (
  tool_x64 Dart || exit 1
  mkdir -p "$FLUTTER_DIR/bin/cache" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$FLUTTER_DIR/bin/cache" dart "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "https://storage.googleapis.com/flutter_infra_release/flutter/$FLUTTER_ENGINE_REVISION/dart-sdk-linux-x64.zip" \
    "$FLUTTER_DART_SHA256" "$stage/dart.zip" \
    && unzip -q "$stage/dart.zip" -d "$stage" \
    && chmod +x "$stage/dart-sdk/bin/"* \
    && [[ -x "$stage/dart-sdk/bin/dart" ]] \
    && printf '%s\n' "$FLUTTER_DART_SHA256" > "$stage/dart-sdk/.setup-kit-sha256" \
    && tool_content_receipt "$stage/dart-sdk" bin/dart \
    && tool_publish_dir "$stage/dart-sdk" "$FLUTTER_DIR/bin/cache/dart-sdk" "$stage" \
    && tool_write "$FLUTTER_ENGINE_REVISION" "$FLUTTER_DIR/bin/cache/engine-dart-sdk.stamp"
)
android_tools_install() (
  tool_x64 android-tools || exit 1
  mkdir -p "$SDK_DIR/cmdline-tools" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$SDK_DIR/cmdline-tools" tools "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_TOOLS_BUILD}_latest.zip" "$ANDROID_TOOLS_SHA256" "$stage/tools.zip" \
    && unzip -q "$stage/tools.zip" -d "$stage" \
    && chmod +x "$stage/cmdline-tools/bin/"* || exit 1
  [[ ! -e "$SDK_DIR/cmdline-tools/$ANDROID_TOOLS_VERSION" ]] || { echo 'drifted Android tools: inspect and move aside first' >&2; exit 1; }
  mv "$stage/cmdline-tools" "$SDK_DIR/cmdline-tools/$ANDROID_TOOLS_VERSION"
)
android_accept() { # yes may SIGPIPE; only sdkmanager's status decides success
  yes | "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK_DIR" --licenses
  local rc=${PIPESTATUS[1]}; return "$rc"
}
if pkg_installed openjdk-21-jdk-headless; then ok "headless JDK 21"
else warn "headless JDK 21 missing"; apt_install openjdk-21-jdk-headless || miss "flutter: headless JDK 21 install failed"; fi
if [[ ! -d "$FLUTTER_DIR" ]]; then
  warn "flutter $FLUTTER_VERSION missing"; do_or_say flutter_clone || miss "flutter: pinned git clone failed"
elif [[ "$(git -C "$FLUTTER_DIR" rev-parse HEAD 2>/dev/null)" != "$FLUTTER_REVISION" ]]; then
  warn "flutter revision drift: expected $FLUTTER_REVISION; preserve checkout and inspect before replacing"
  miss "flutter: checkout revision does not match pin"
else ok "flutter revision $FLUTTER_VERSION"; fi
if ! flutter_dart_ready; then
  warn "pinned Dart SDK missing or unverified"
  if (( INSTALL )) && [[ -x "$FLUTTER_DIR/bin/flutter" && "$(git -C "$FLUTTER_DIR" rev-parse HEAD 2>/dev/null)" == "$FLUTTER_REVISION" ]]; then
    flutter_dart_install || miss "flutter: Dart archive verification failed"
  fi
fi
if flutter_dart_ready && [[ "$(cat "$FLUTTER_DIR/bin/cache/setup-kit-android.complete" 2>/dev/null)" == "$FLUTTER_REVISION:$FLUTTER_DART_SHA256" && -f "$FLUTTER_DIR/bin/cache/flutter.version.json" ]] && python3 -I - "$FLUTTER_DIR/bin/cache/flutter.version.json" "$FLUTTER_VERSION" "$FLUTTER_DART_VERSION" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); sys.exit(0 if d['frameworkVersion']==sys.argv[2] and d['dartSdkVersion']==sys.argv[3] else 1)
except (OSError,ValueError,KeyError): sys.exit(1)
PY
then ok "flutter/Dart cache matches pin"
else
  warn "flutter/Dart cache missing or drifted"
  if flutter_dart_ready && [[ -x "$FLUTTER_DIR/bin/flutter" && "$(git -C "$FLUTTER_DIR" rev-parse HEAD 2>/dev/null)" == "$FLUTTER_REVISION" ]]; then
    flutter_precache() {
      rm -f "$FLUTTER_DIR/bin/cache/setup-kit-android.complete" || return 1
      env FLUTTER_PREBUILT_ENGINE_VERSION="$FLUTTER_ENGINE_REVISION" "$FLUTTER_DIR/bin/flutter" precache --android \
        && tool_write "$FLUTTER_REVISION:$FLUTTER_DART_SHA256" "$FLUTTER_DIR/bin/cache/setup-kit-android.complete"
    }
    do_or_say flutter_precache || miss "flutter: Android precache failed"
  fi
fi
if [[ -x "$SDK_DIR/cmdline-tools/$ANDROID_TOOLS_VERSION/bin/sdkmanager" ]] \
    && [[ "$(tool_property "$SDK_DIR/cmdline-tools/$ANDROID_TOOLS_VERSION/source.properties" Pkg.Revision)" == "$ANDROID_TOOLS_VERSION" ]]; then
  ok "Android command-line tools $ANDROID_TOOLS_VERSION"
else warn "Android command-line tools $ANDROID_TOOLS_VERSION missing or drifted"; do_or_say android_tools_install || miss "flutter: Android tools archive failed"; fi
if [[ "$(readlink "$SDK_DIR/cmdline-tools/latest" 2>/dev/null)" != "$ANDROID_TOOLS_VERSION" ]]; then
  warn "Android tools stable link missing or drifted"
  (( ! INSTALL )) || [[ -x "$SDK_DIR/cmdline-tools/$ANDROID_TOOLS_VERSION/bin/sdkmanager" ]] \
    && do_or_say tool_link "$ANDROID_TOOLS_VERSION" "$SDK_DIR/cmdline-tools/latest" || miss "flutter: Android stable link unavailable"
fi
if [[ ! -s "$SDK_DIR/licenses/android-sdk-license" ]]; then
  warn "Android SDK licenses missing"
  (( ! INSTALL )) || [[ -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" ]] \
    && do_or_say android_accept || miss "flutter: Android licenses not accepted"
fi
ANDROID_MISSING=()
for package in platform-tools "platforms;$ANDROID_PLATFORM" "build-tools;$ANDROID_BUILD_TOOLS" "ndk;$ANDROID_NDK"; do
  props="$SDK_DIR/${package//;/\/}/source.properties"
  expected="${package#*;}"
  case "$package" in
    platform-tools) value=$(tool_property "$props" Pkg.Revision); pattern='^[0-9]+(\.[0-9]+)*$' ;;
    platforms\;*) value=$(tool_property "$props" AndroidVersion.ApiLevel); pattern="^${ANDROID_PLATFORM#android-}$" ;;
    *) value=$(tool_property "$props" Pkg.Revision); pattern="^${expected//./\\.}$" ;;
  esac
  if [[ -s "$props" && "$value" =~ $pattern ]]; then ok "Android $package"
  else warn "Android $package missing or revision drifted"; ANDROID_MISSING+=("$package"); fi
done
if (( ${#ANDROID_MISSING[@]} )); then
  if (( ! INSTALL )) || [[ -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" && -x "$JAVA_DIR/bin/java" ]]; then
    do_or_say "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK_DIR" --install "${ANDROID_MISSING[@]}" || miss "flutter: SDK packages failed"
  else miss "flutter: SDK packages deferred until JDK/tools are available"; fi
fi
source "$KIT_DIR/components/bundled-python.sh"
bundle_python_floor 'NDK Python' \
  "$SDK_DIR/ndk/$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/python3/bin/python3" no
# SSH's bash reads .bashrc even for remote commands, before its interactive
# early return. Never write through a dotfile symlink into another checkout.
ENV_FILE="$HOME/.config/setup-kit/headless-env.sh"
ENV_WANT='export ANDROID_HOME="$HOME/Android/Sdk" ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export JAVA_HOME="'"$JAVA_DIR"'"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/development/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"'
if [[ ! -f "$ENV_FILE" || "$(cat "$ENV_FILE")" != "$ENV_WANT" ]]; then
  warn "headless shell environment missing or drifted"; do_or_say tool_write "$ENV_WANT" "$ENV_FILE" || miss "flutter: shell environment failed"
fi
BASH_LINE='[ ! -r "$HOME/.config/setup-kit/headless-env.sh" ] || . "$HOME/.config/setup-kit/headless-env.sh"'
if [[ -L "$HOME/.bashrc" ]]; then
  ok "managed bashrc preserved; SSH environment is independent"
elif [[ "$(head -1 "$HOME/.bashrc" 2>/dev/null)" != "$BASH_LINE" ]]; then
  warn "headless SSH environment missing before bashrc early return"
  BASH_WANT="$BASH_LINE"$'\n'"$(cat "$HOME/.bashrc" 2>/dev/null || true)"
  # The existing shell file may contain private values: never pass its body
  # through do_or_say, which logs arguments. Keep the existing file mode.
  headless_bashrc_write() { tool_write "$BASH_WANT" "$HOME/.bashrc"; }
  do_or_say headless_bashrc_write || miss "flutter: bashrc is externally managed; add the environment source at its start"
fi
T3_ENV="[Service]
Environment=\"ANDROID_HOME=$SDK_DIR\" \"ANDROID_SDK_ROOT=$SDK_DIR\" \"JAVA_HOME=$JAVA_DIR\"
Environment=\"PATH=$HOME/.local/bin:$HOME/.bun/bin:$FLUTTER_DIR/bin:$JAVA_DIR/bin:$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
T3_DROP="$HOME/.config/systemd/user/t3code.service.d/60-headless.conf"
if [[ ! -f "$T3_DROP" || "$(cat "$T3_DROP")" != "$T3_ENV" ]]; then
  warn "headless T3 environment missing or drifted"
  if do_or_say tool_write "$T3_ENV" "$T3_DROP"; then
    # shellcheck disable=SC2034 # consumed by 07 T3 integration
    (( ! INSTALL )) || HEADLESS_T3_RELOAD=1
  else miss "flutter: T3 environment failed"; fi
fi

source "$KIT_DIR/components/headless-ssh.sh"
