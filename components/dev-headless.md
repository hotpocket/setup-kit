# Headless runtime packages

`group_dev_headless=yes` selects `manifests/apt/optional/dev-headless.list`.
Default is off. The normal apt phase checks installed packages and installs
only missing ones, using the kit's noninteractive/removal guards. Apt's disk
preflight measures the package set; no desktop group is required.

The group contains Playwright 1.62.1's **tools and chromium** arrays for
`ubuntu26.04-x64`, plus ripgrep, xauth, Mesa software GL/EGL and DejaVu fonts.
It excludes Firefox/WebKit libraries and browser executables. Source:
[Playwright nativeDeps](https://github.com/microsoft/playwright/blob/v1.62.1/packages/playwright-core/src/server/registry/nativeDeps.ts).

Edit `capture/90-generate-manifests.py`, then regenerate this group. Its package
set is additive: regeneration must retain packages already requested by other
groups. The generator test compares that behavior to the previous placement.
When the Playwright pin changes, review its nativeDeps table before changing
this group or enabling browser installation.

Test: `bash tests/test-dev-headless.sh`.

Run all agent-tool calibrations with `bash tests/run-agent-tools.sh`. It takes
no lock and runs them only on dev via dev-run. If dev-run fails or is missing,
it fails; nothing runs. Needs no model, sudo or network beyond reaching dev.
