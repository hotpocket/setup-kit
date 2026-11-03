#!/bin/bash
source "$KIT_DIR/components/tool-common.sh"
source "$KIT_DIR/components/flutter-cache.sh"
section "flutter headless ($MODE) — components/flutter-headless.md"
FLUTTER_DIR="$HOME/development/flutter"
SDK_DIR="$HOME/Android/Sdk"
JAVA_DIR="$TOOL_ROOT/usr/lib/jvm/java-21-openjdk-amd64"
export ANDROID_HOME="$SDK_DIR" ANDROID_SDK_ROOT="$SDK_DIR" JAVA_HOME="$JAVA_DIR"
export PATH="$FLUTTER_DIR/bin:$JAVA_DIR/bin:$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:$PATH"
# The verified release ships Dart and the compiled tool. A Git clone would
# bootstrap flutter_tools with unpinned Pub archives on its first invocation.
flutter_release_install() (
  tool_x64 Flutter || exit 1
  local parent owner stage backup
  parent=$(dirname "$FLUTTER_DIR")
  mkdir -p "$parent" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$parent" flutter "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "$FLUTTER_RELEASE_URL" "$FLUTTER_RELEASE_SHA256" "$stage/flutter.tar.xz" \
    && tar --no-same-owner -xJf "$stage/flutter.tar.xz" -C "$stage" \
    && [[ "$(git -C "$stage/flutter" rev-parse HEAD)" == "$FLUTTER_REVISION" ]] \
    && python3 -I "$KIT_DIR/components/flutter-release.py" prepare "$KIT_DIR" "$stage/flutter" \
    && python3 -I "$KIT_DIR/components/flutter-release.py" seal "$KIT_DIR" "$stage/flutter" || exit 1
  if [[ -e "$FLUTTER_DIR" || -L "$FLUTTER_DIR" ]]; then
    if [[ ! -L "$FLUTTER_DIR" ]] && { \
      python3 -I "$KIT_DIR/components/flutter-release.py" managed "$KIT_DIR" "$FLUTTER_DIR" \
      || { [[ "$(git -C "$FLUTTER_DIR" rev-parse HEAD 2>/dev/null)" == "$FLUTTER_REVISION" ]] \
        && [[ -z "$(git -C "$FLUTTER_DIR" status --porcelain --untracked-files=all)" ]]; }; }; then
      mv -T "$FLUTTER_DIR" "$stage/previous" || exit 1
    else
      # Keep unrelated or locally edited trees outside disposable staging.
      backup=$(mktemp -d "$parent/flutter.backup.XXXXXX") || exit 1
      mv -T "$FLUTTER_DIR" "$backup" || exit 1
      warn "previous Flutter tree preserved in $backup"
    fi
  fi
  mv -T "$stage/flutter" "$FLUTTER_DIR"
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
if tool_flutter_release_ready; then ok "flutter release $FLUTTER_VERSION"
else
  warn "verified Flutter release missing or drifted"
  do_or_say flutter_release_install || miss "flutter: release archive verification or publication failed"
fi
if tool_flutter_release_ready && tool_flutter_cache_ready && [[ "$(cat "$FLUTTER_DIR/bin/cache/setup-kit-android.complete" 2>/dev/null)" == "$FLUTTER_REVISION:$FLUTTER_RELEASE_SHA256" && -f "$FLUTTER_DIR/bin/cache/flutter.version.json" ]] && python3 -I - "$FLUTTER_DIR/bin/cache/flutter.version.json" "$FLUTTER_VERSION" "$FLUTTER_DART_VERSION" <<'PY2'
import json,sys
try:
 d=json.load(open(sys.argv[1])); sys.exit(0 if d['frameworkVersion']==sys.argv[2] and d['dartSdkVersion']==sys.argv[3] else 1)
except (OSError,ValueError,KeyError): sys.exit(1)
PY2
then ok "flutter/Dart cache matches pin"
else
  warn "flutter/Dart cache missing or drifted"
  if tool_flutter_release_ready; then
    flutter_precache() {
      rm -f "$FLUTTER_DIR/bin/cache/setup-kit-android.complete" || return 1
      tool_flutter_cache_ready || flutter_cache_install || return 1
      # Refuse unexpected downloads from either bootstrap Pub or engine storage.
      # Empty tool args keep the vendor snapshot's compile key unchanged.
      env FLUTTER_TOOL_ARGS= PUB_CACHE="$FLUTTER_DIR/.setup-kit-pub-cache" PUB_HOSTED_URL=setup-kit-verified://offline \
        FLUTTER_STORAGE_BASE_URL=setup-kit-verified://offline FLUTTER_PREBUILT_ENGINE_VERSION="$FLUTTER_ENGINE_REVISION" \
        "$FLUTTER_DIR/bin/flutter" precache --android \
        && tool_flutter_release_ready && tool_flutter_cache_ready \
        && tool_write "$FLUTTER_REVISION:$FLUTTER_RELEASE_SHA256" "$FLUTTER_DIR/bin/cache/setup-kit-android.complete"
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
  if [[ -s "$props" && "$value" =~ $pattern ]] && tool_android_payload "$SDK_DIR" "$package"; then ok "Android $package"
  else warn "Android $package missing or revision drifted"; ANDROID_MISSING+=("$package"); fi
done
# sdkmanager may skip a package whose metadata survived payload loss. Install
# missing packages into a private SDK root and publish only complete packages.
android_packages_install() (
  owner=$BASHPID
  stage=$(tool_stage "$SDK_DIR" android-packages "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/sdk/licenses" || exit 1
  cp -a "$SDK_DIR/licenses/." "$stage/sdk/licenses/" || exit 1
  "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$stage/sdk" --install "${ANDROID_MISSING[@]}" || exit 1
  for package in "${ANDROID_MISSING[@]}"; do
    directory=${package//;/\/}
    tool_android_payload "$stage/sdk" "$package" && [[ -s "$stage/sdk/$directory/source.properties" ]] || exit 1
  done
  for package in "${ANDROID_MISSING[@]}"; do
    directory=${package//;/\/}
    previous="$stage/previous-${package//;/-}"
    mkdir -p "$(dirname "$SDK_DIR/$directory")" "$previous" || exit 1
    tool_publish_dir "$stage/sdk/$directory" "$SDK_DIR/$directory" "$previous" || exit 1
  done
)
if (( ${#ANDROID_MISSING[@]} )); then
  if (( ! INSTALL )) || [[ -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" && -x "$JAVA_DIR/bin/java" ]]; then
    do_or_say android_packages_install || miss "flutter: SDK packages failed"
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
source "$KIT_DIR/components/headless-login.sh"
