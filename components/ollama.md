# ollama — opt-in component (workstation profile)

Local LLM runtime. Backs the `wat` alias from `~/git/.configs`
(`alias wat="ollama run codellama"`) — a quick "ask the local model" from the
terminal, no network/API key. Single Go binary + a background server that
serves models over a local HTTP API (127.0.0.1:11434).

- Site: https://ollama.com
- Repo: https://github.com/ollama/ollama (MIT)

## Why it's opt-in (not default)

- Installs via its own script (`curl -fsSL https://ollama.com/install.sh | sh`),
  NOT apt — so it's outside the manifest/doctor model the default packages use.
- Models are large (codellama ~3.8 GB) and the pull is the real cost; not
  something to drop on every fresh box.
- GPU optional: runs CPU-only, uses NVIDIA/AMD if present (the installer
  detects and wires up the runtime).

## Install

1. `curl -fsSL https://ollama.com/install.sh | sh` — installs
   `/usr/local/bin/ollama` and a systemd service (`ollama.service`), creates
   an `ollama` user. Root needed (the script sudo's).
2. `ollama pull codellama` — the model `wat` runs. Done in install mode so the
   alias works immediately; skipped in `check` (just reports missing).

## Setup-kit integration

- **OPT-IN** — `component_ollama=yes` in `hosts/<hostname>.conf` to enable
  (default `no`). Provisioned by `profiles/workstation/07-components.sh`.
- `check` mode: reports whether `ollama` and the `codellama` model are present,
  changes nothing.
- Swap the model by editing the `wat` alias + the pull in 07-components.sh if a
  different default is wanted (e.g. `llama3`, `qwen2.5-coder`).
- `ollama_coder_model=<tag>` in the host conf pulls an additional coding model
  for editor/agentic use (default empty = none). LinuxBeast2 uses
  `qwen3-coder:30b` (~18 GB, MoE 3B-active, fits the 3090's 24 GB VRAM at Q4,
  ~50 tok/s). Point Continue.dev/Cline at the local API (127.0.0.1:11434).

## Notes

- Server listens on localhost only (127.0.0.1:11434) — no LAN exposure by
  default. To expose, set `OLLAMA_HOST` in the service override (not done here).
- `ollama list` shows pulled models; `ollama rm <model>` reclaims disk.
- No telemetry beyond version/update checks; models run fully local.
