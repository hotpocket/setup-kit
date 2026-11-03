# Headless Flutter / Android

`component_flutter_headless=yes` enables this stack. Unset/no does nothing.
The pin file is `manifests/tool-versions.conf`.

- Flutter 3.47.2, exact upstream commit, Dart 3.13.2, at `$HOME/development/flutter`.
- Android command-line tools 22.0 (build 15859902), vendor-published SHA256,
  at `$HOME/Android/Sdk/cmdline-tools/22.0`, with `latest` pointing there.
- `platform-tools`, `platforms;android-36`, `build-tools;36.0.0`,
  `ndk;28.2.13676358`; licenses accepted through `sdkmanager --licenses`.
- Apt `openjdk-21-jdk-headless`. No Studio, emulator, system image or AVD.

Check reads git revision, Flutter cache metadata, Android package receipts,
licenses and environment content. It does not run Flutter or sdkmanager.
Install stages the verified clone/archive, pre-caches Android artifacts and
requests only absent/drifted SDK packages. Existing drifted Flutter checkouts
and command-tool version directories require inspection before replacement.
SDKmanager verifies its repository-managed downloads; its packages are named
explicitly, rather than downloading an unversioned Android installer.

Receipt assignments accept spaces around `=`, including NDK's format.
NDK's bundled Python has pip but no `_ssl` module. Its pip floor uses a
hash-checked wheel downloaded through host curl, then installed offline by
that interpreter. This preserves the NDK and adds no certifi package.
Matching package floors require no download on subsequent passes.

The environment file is `$HOME/.config/setup-kit/headless-env.sh`. A source
line goes first in a **regular** `.bashrc`, before Ubuntu's noninteractive
return, so SSH's bash receives PATH/ANDROID_HOME without .configs. The component
preserves managed symlinks. SSH independently receives the four variables
through `.ssh/environment` (mode 600) and an sshd drop-in allowing exactly
PATH, ANDROID_HOME, ANDROID_SDK_ROOT and JAVA_HOME. The component validates
sshd configuration and reloads the service without stopping it; invalid
configuration restores the previous file. This works with the agent role's
linked `.bashrc`. See [OpenSSH's environment allowlist](https://man.openbsd.org/sshd_config#PermitUserEnvironment).
T3 receives the same paths through `t3code.service.d/60-headless.conf`; phase
07's existing T3 restart logic applies a changed environment. A new service
receives it on first start. Other shells need to source the environment file.

JDK 21 is an LTS within Gradle 9.3.1's supported JVM 17–25 range; AGP 9.1
requires at least 17. Java 17 bytecode targets in t3-voice do not require the
build JVM to be 17. Tools 22 retain the licenses interface used by Flutter
3.47.2; tools 23 changed it. Sources: [Gradle compatibility](https://docs.gradle.org/9.3.1/userguide/compatibility.html),
[AGP 9.1 compatibility](https://developer.android.com/build/releases/agp-9-1-0-release-notes),
[Google's download/checksum table](https://developer.android.com/studio),
[Google's repository metadata](https://dl.google.com/android/repository/repository2-3.xml),
[Flutter release tracker](https://github.com/flutter/flutter/issues/191758).

Test: `bash tests/test-flutter-headless.sh`. A real headless build remains a
VM acceptance check; provisioning is never run on Beast by this slice.
