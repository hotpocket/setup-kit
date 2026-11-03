# Blender batch renderer

`component_blender=yes` enables the official Linux x64 archive, pinned to
5.2.2 LTS as observed on Beast. Unset/no leaves the machine alone.
Check reads the installed renderer's version and the two links; it downloads
nothing. Install verifies SHA256 before publishing the extracted directory:

- `$HOME/.local/opt/blender-<version>-linux-x64`
- `$HOME/.local/opt/blender` → that version
- `$HOME/.local/bin/blender` → the stable directory's executable

A second install makes no changes. A drifted version directory is preserved
for inspection rather than overwritten. No launcher, desktop registration,
GPU driver or session service is installed. `group_dev_headless=yes` supplies
CPU GL/Xvfb dependencies for rendering; callers choose their rendering flags.

Pins live in `manifests/tool-versions.conf`. The SHA256 comes from Blender's
[release checksum file](https://mirror.blender.org/release/Blender5.2/blender-5.2.2.sha256).
Staging and the final directory share a filesystem; publication uses rename.
The preflight reserves archive plus extracted size, pending measurement on dev.

Test: `bash tests/test-blender.sh`.
