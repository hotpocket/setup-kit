# uv / uvx

`component_uv=yes` enables this component; unset/no does nothing.
Check reports absent binaries or version drift without downloading. Install
publishes standalone `uv` and `uvx` in `$HOME/.local/bin` after verifying the
archive. Both must report the pinned version; a second install does nothing.
No Python environment or interactive shell setup is copied from another host.

The pin is 0.12.23, matching the newer observed ai-3090 installation. Beast's
0.9.18 remains unchanged because this component defaults off. Project locks
that require another uv version stay project-owned.

Version and SHA256 live in `manifests/tool-versions.conf`, from Astral's
[published checksum](https://github.com/astral-sh/uv/releases/download/0.12.23/uv-x86_64-unknown-linux-gnu.tar.gz.sha256).
Only Linux x86_64 is admitted. Downloads use staging names; dead-owner staging
is recovered on rerun, and final binaries appear by rename. The disk preflight
includes an explicit download/extraction allowance.

Test: `bash tests/test-uv.sh`; interrupted download: `bash tests/test-tools-interrupted.sh`.
