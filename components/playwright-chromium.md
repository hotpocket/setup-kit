# gstack Chromium

`component_playwright_chromium=yes` opts in; unset/no does nothing. Phase 08
calls this component after its existing gstack build, OS pin check and AppArmor
profile handling. Keep `component_claude_skills=yes` and select gstack.

The reviewed pin is Playwright 1.62.1 on Ubuntu 26.04 x64. Both gstack's declared
and installed versions must match this reviewed release before the browser CLI
runs. Playwright 1.61 introduced [Ubuntu 26.04 support](https://playwright.dev/docs/release-notes#version-161).
The runtime package group is tied to 1.62.1's own nativeDeps table.

The CLI uses Node from PATH or the installed nvm default, queried without
activating an interactive shell. Check uses the project's installed `node_modules/playwright/cli.js` dry-run to
read browser revisions and cache locations. Missing installation-complete
markers are drift. Install invokes that same CLI with `install chromium`,
which installs Chromium and its headless shell (plus vendor-required ffmpeg).
A second install does not invoke the installer again.

The cache is `$HOME/.cache/ms-playwright`, regardless of an inherited custom
cache variable. Never use WebKit in that cache, `install-deps`, a fetched npx
version, or `--no-sandbox`. The existing phase owns AppArmor; this component
adds no competing profile. Keep WebKit in its separately managed cache.

Test: `bash tests/test-playwright-chromium.sh`.
