#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools; run_tools install
assert 'flutter headless default off' '[[ ! -e "$HOME/development" ]] && [[ -z "$(mutations)" ]]'
conf_tools component_flutter_headless=yes; run_tools check
assert 'flutter check reports missing SDK and makes no mutation' 'grep -q "WARN.*flutter.*missing" "$TMP/out" && [[ -z "$(mutations)" ]] && [[ ! -e "$HOME/.bashrc" ]]'
printf '# private bashrc sentinel\nreturn\n' > "$HOME/.bashrc"; chmod 600 "$HOME/.bashrc"
run_tools install
assert 'bashrc edits preserve privacy and its existing mode' '! grep -q "private bashrc sentinel" "$TMP/out" "$KIT_LOG_DIR/ws-07-components.log" && [[ "$(stat -c %a "$HOME/.bashrc")" == 600 ]]'
assert 'Flutter release pinned and Android tools checksum enforced' '[[ -x "$HOME/development/flutter/bin/flutter" && -x "$HOME/Android/Sdk/cmdline-tools/latest/bin/sdkmanager" ]] && grep -Fq "$FLUTTER_RELEASE_URL" "$CALLS" && grep -q "4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583" "$STATE/checksum-input"'
assert 'headless SDK packages and JDK21 only' '[[ -f "$HOME/Android/Sdk/platforms/android-36/source.properties" && -f "$HOME/Android/Sdk/build-tools/36.0.0/source.properties" && -f "$HOME/Android/Sdk/ndk/28.2.13676358/source.properties" && -s "$HOME/Android/Sdk/licenses/android-sdk-license" ]] && grep -q "apt-get .*openjdk-21-jdk-headless" "$CALLS" && ! grep -qE "sdkmanager .*emulator|system-images|avdmanager|android-studio" "$CALLS"'
assert 'noninteractive SSH and service get environment without configs' 'env -i HOME="$HOME" PATH=/usr/bin:/bin bash --noprofile -c '\''source "$HOME/.bashrc"; [[ "$ANDROID_HOME" == "$HOME/Android/Sdk" && "$PATH" == *"$HOME/development/flutter/bin"* ]]'\'' && [[ -s "$HOME/.config/systemd/user/t3code.service.d/60-headless.conf" ]]'
run_tools install
assert 'flutter second install has no mutation with spaced NDK receipt' '[[ -z "$(mutations)" ]] && ! grep -q "bundle-python .*install" "$CALLS"'
PY="$HOME/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/python3/bin/python3"
assert 'NDK bundled pip floor repaired without adding certifi' 'grep -q "26.2.2" "${PY%/*}/packages.json" && grep -q '\''"certifi": null'\'' "${PY%/*}/packages.json"'
for props in "$HOME/Android/Sdk/cmdline-tools/22.0/source.properties" "$HOME/Android/Sdk/platform-tools/source.properties" "$HOME/Android/Sdk/platforms/android-36/source.properties" "$HOME/Android/Sdk/build-tools/36.0.0/source.properties"; do sed -i 's/=/ = /' "$props"; done
run_tools install
assert 'all Android receipt checks accept whitespace around equals' '[[ -z "$(mutations)" ]] && ! grep -q "bundle-python .*install" "$CALLS"'
printf 'Pkg.Revision=35.0.0\n' > "$HOME/Android/Sdk/build-tools/36.0.0/source.properties"; run_tools check
assert 'Android build-tools revision drift is visible without SDK mutation' 'grep -q "WARN.*Android build-tools;36.0.0.*drift" "$TMP/out" && [[ -z "$(mutations)" ]]'
run_tools install
assert 'Android build-tools drift is repaired through sdkmanager' 'grep -q "sdkmanager .*--install build-tools;36.0.0" "$CALLS"'
# Agent role's bashrc is a managed symlink, with an early noninteractive return.
rm -f "$HOME/.bashrc"
printf 'case $- in *i*) ;; *) return ;; esac\n' > "$HOME/agent-bashrc"
ln -s "$HOME/agent-bashrc" "$HOME/.bashrc"
run_tools install
assert 'managed bashrc stays linked; SSH has an independent environment' '[[ -L "$HOME/.bashrc" && -f "$ROOT/etc/ssh/sshd_config.d/60-setup-kit-headless.conf" && -s "$HOME/.ssh/environment" && "$(stat -c %a "$HOME/.ssh/environment")" == 600 ]] && grep -qx "PermitUserEnvironment PATH,ANDROID_HOME,ANDROID_SDK_ROOT,JAVA_HOME" "$ROOT/etc/ssh/sshd_config.d/60-setup-kit-headless.conf" && grep -qx "ANDROID_HOME=$HOME/Android/Sdk" "$HOME/.ssh/environment"'
run_tools install
assert 'managed bashrc and SSH environment converge without rewrites' '[[ -L "$HOME/.bashrc" ]] && ! grep -q "bashrc is externally managed" "$TMP/out" && [[ -z "$(mutations)" ]]'
printf 'wrong\n' > "$HOME/development/flutter/HEAD"; run_tools check
assert 'flutter detects revision drift' 'grep -q "WARN.*Flutter.*release" "$TMP/out" && [[ -z "$(mutations)" ]]'
# Failed SSH validation rolls back; a missing activation marker is retried.
printf '# previous ssh config\n' > "$ROOT/etc/ssh/sshd_config.d/60-setup-kit-headless.conf"
touch "$STATE/sshd-fail"; run_tools install
assert 'invalid SSH config restores its previous file without reloading' 'grep -qx "# previous ssh config" "$ROOT/etc/ssh/sshd_config.d/60-setup-kit-headless.conf" && ! grep -q "systemctl reload ssh.service" "$CALLS" && grep -q "MISS:.*SSH environment allowlist" "$TMP/out"'
rm "$STATE/sshd-fail"; run_tools install
assert 'SSH validation recovery reloads and records activation' 'grep -q "systemctl reload ssh.service" "$CALLS" && [[ -s "$HOME/.config/setup-kit/headless-ssh.active" ]]'
rm "$HOME/.config/setup-kit/headless-ssh.active"; run_tools install
assert 'interrupted SSH activation is retried rather than silently accepted' 'grep -q "systemctl reload ssh.service" "$CALLS" && [[ -s "$HOME/.config/setup-kit/headless-ssh.active" ]]'
finish
