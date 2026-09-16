# t3code — opt-in component (workstation + worker profiles)

T3 Code (pingdotgg/t3code, MIT): a web/desktop front end for the coding agents
already installed on a box — Claude Code, Codex, OpenCode and others. A Node
server owns the providers, terminals, git and files; web, desktop and phone
clients talk to it over authenticated RPC. It has **no model access of its
own**: the Claude provider is the `claude` CLI and its own login
(`claude auth login`), so `component_claude_code` (phase 08) is the
prerequisite and nothing key-shaped is stored for it.

- Site / docs: https://t3.codes — https://github.com/pingdotgg/t3code/tree/main/docs/user
- Source: https://github.com/pingdotgg/t3code

## What it installs

1. `curl -fsSL https://t3.codes/install.sh | sh` — a **self-contained** release
   archive (64 MB linux-x64 tar.gz; no node, npm or compiler) unpacked into
   `~/.t3/runtime/versions/<version>`, with `~/.local/bin/t3` linked to it.
   Nothing under `/usr`, no sudo. `T3CODE_CHANNEL=nightly|preview` and
   `T3CODE_VERSION=` steer the installer; the kit follows `stable`.
2. `~/.config/systemd/user/t3code.service.d/setup-kit.conf` — a drop-in with
   `T3CODE_HOST` / `T3CODE_PORT` from the host conf. **Why a drop-in:** `t3
   service install` renders the unit itself and re-renders it on every
   `t3 update`, so anything written into the unit is lost on the next update.
   The launcher spawns `serve` with its inherited environment
   (`apps/server/src/serviceLauncher.ts`), so the env reaches the server.
   Reconciled by content, like `zram-generator.conf`; written *before* the
   first `t3 service install` so the first start already binds correctly.
3. `t3 service install` — writes `~/.config/systemd/user/t3code.service`
   (`Restart=always`, `OOMPolicy=continue`, `WantedBy=default.target`, logs
   to a file `t3 service status` names), enables and starts it, and enables
   linger for the user (prints the `sudo loginctl enable-linger` line when it
   cannot). The worker profile already lingers (03-headless).

## Host conf

- `component_t3code=yes` (default `no`). Provisioned by `07-components.sh`.
- `t3code_host=` bind address, default `127.0.0.1` (loopback: only a browser on
  the box itself). `0.0.0.0` or the LAN/tailnet IP to reach it from other
  devices — the worker template says so, because a worker is *only* reached
  from elsewhere. Clients then pair once: `t3 pair` prints a one-time link/QR;
  a loopback bind cannot be paired from another device.
- `t3code_port=` default `3773` (T3's `DEFAULT_PORT`). Pinned on purpose: with
  no port set, T3 picks the next free one, and a doctor cannot probe "next free".

## Doctor / verify

- `check`: `t3` on PATH + version; `claude` on PATH (warns, does not install —
  that is phase 08's job); drop-in matches by content; unit installed +
  enabled; unit active. Changes nothing; every gap is a `[would]`.
- `install`: installer → drop-in → `t3 service install` (fresh) or
  `daemon-reload` + `restart` (drop-in changed) → restart if enabled but dead.
- `verify.sh`: wanted means *listening*, not just a binary — passes only with
  `t3code.service` active; fails by name otherwise; "not wanted" when off.
- `tests/test-t3code.sh` calibrates all of it with a stubbed `t3`,
  `systemctl` and `curl` (no network). The drop-in comparison, mutated to
  always-match, turns three assertions red.

## Day 2

- Update: `t3 update` (asks before restarting; `--yes` from a script). The
  kit does not update it — same policy as claude's self-updater.
- Status / logs: `t3 service status`; `systemctl --user status t3code.service`.
- Remove: `t3 uninstall` (service + launcher + runtime; keeps
  `~/.t3/userdata`); the kit's drop-in dir is left for the next install.
- Second Claude account: `CLAUDE_CONFIG_DIR=~/.claude_work claude auth login`,
  then add a provider instance in Settings → Providers with that dir.

## Notes

- Alternative routes not used: `npx t3@latest` (needs node; the worker has
  `lang_node=no`), the Electron AppImage (desktop-only), `yay t3code-bin`
  (Arch). Build-from-source needs node 24 + pnpm 11 and is not for a
  provisioned box.
- A non-loopback bind is an authenticated surface (pairing tokens), not an
  open one — but it is still a listener on the LAN; keep the port off any
  router forward and prefer a tailnet IP over `0.0.0.0` when one exists.
- Size row: `manifests/sizes.conf` `component_t3code` — estimate until the
  first real install is measured (`du -sh ~/.t3`).
