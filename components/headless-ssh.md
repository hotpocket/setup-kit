# Headless SSH environment

Internal to `component_flutter_headless`, with no separate flag. It supplies
SSH commands with the same SDK/JDK paths as the T3 service, independently of
.configs or an interactive shell.

Owns `.ssh/environment` entries for PATH, ANDROID_HOME, ANDROID_SDK_ROOT and
JAVA_HOME, preserving unrelated entries and mode 600. Never logs its contents.
An sshd drop-in accepts only these variable names. Check compares content and
mode without sudo. Install publishes files by rename, validates `sshd -t` and
reloads SSH. Validation failure restores the previous drop-in and does not
reload. Existing connections remain active. Identical files cause no writes.

`PermitUserEnvironment` defaults off in OpenSSH; this narrow opt-in allowlist
is required for `.ssh/environment` to apply. Other users retain their existing
PATH unless they supply allowed entries in their own environment file.

Tested through `tests/test-flutter-headless.sh` with fake HOME, root and sshd.
