# codex — opt-in component (workstation + worker profiles)

OpenAI's Codex CLI (openai/codex, Apache-2.0): the second coding agent T3 Code
fronts (`components/t3code.md`). A ChatGPT Plus, Pro, Business, Edu or
Enterprise plan includes it; Free does not. Like `claude`, it carries its own
login — nothing key-shaped is stored by the kit.

- Docs: https://learn.chatgpt.com/docs/codex/cli — auth: https://learn.chatgpt.com/docs/auth
- Source: https://github.com/openai/codex

## What it installs

1. `curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh`
   — a musl release unpacked into
   `~/.codex/packages/standalone/releases/<version>-x86_64-unknown-linux-musl`,
   a `current` symlink beside it, and `~/.local/bin/codex` linked through it
   (plus `codex-code-mode-host`). No node, no npm, no sudo. Measured 324M on
   ai-3090 (0.154.0). `CODEX_INSTALL_DIR` overrides the dir; not used. The installer edits a
   shell profile to add `~/.local/bin` to PATH **only when it is not already
   there** — on a kit box it is (claude lives there), so nothing is touched.
   Non-interactive mode skips its "Start Codex now?" prompt.
2. Nothing else. `~/.codex/auth.json`, config and sessions arrive with the
   first login.

## Login — yours, not the kit's

Headless box, no browser: device-code flow.

```sh
codex login --device-auth
```

Enable *device code login* first in ChatGPT → Settings → Security (personal)
or workspace permissions (Business). Alternatives the docs give: run `codex
login` on a machine with a browser and copy `~/.codex/auth.json` over; or
forward the callback with `ssh -L 1455:localhost:1455`. `codex login status`
exits 0 when logged in — that is what the doctor and verify.sh read.

## Host conf

- `component_codex=yes` (default `no`). Provisioned by `07-components.sh`.
- No other knobs. A second account is a t3code provider instance with its
  own `CODEX_HOME` (t3code's `docs/user/providers-codex.md`).

## Doctor / verify

- `check`: binary + version; login state (warns and names the device-auth
  command; proposes nothing — credentials are never the kit's).
- `install`: runs the installer when the binary is missing. Never logs in.
- `verify.sh`: wanted means usable by t3code — fails by name when the binary
  is missing *or* not logged in. `tests/test-codex.sh` calibrates it with a
  stubbed `codex` and `curl`; the login check mutated to always-true turns
  the not-logged-in assertion red.

## Notes

- t3code finds `codex` on its service PATH (`~/.local/bin` is first in the
  systemd user environment here); no provider config needed. Settings →
  Providers has a *Binary path* field if a box differs.
- Update: same installer line, or `codex update`. The kit does not update it.
- An npm-managed codex on the same box is ambiguous (PATH order decides);
  the installer warns and offers to remove it. The kit has none.
- Size row: `manifests/sizes.conf` `component_codex` — measured 324M after the
  first install (2026-09-16).
