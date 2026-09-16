# chatterbox — opt-in component (workstation + worker profiles)

Chatterbox-TTS (Resemble AI), the engine the audiobook line renders with.
`audiobook/scripts/render-book.sh`, `chatterbook/build_book.sh` and `wbt` all
pin one interpreter: `~/.pyenv/versions/chatterbox/bin/python3` (`CHATTERBOX_PY`
overrides). The name is the contract, not the patch version — stable across
machines.

- Package: https://pypi.org/project/chatterbox-tts/ (`chatterbox.tts_turbo.ChatterboxTurboTTS`)
- Source: https://github.com/resemble-ai/chatterbox

## What it installs

1. `pyenv virtualenv <3.12.x> chatterbox` — a dedicated venv off the kit's
   pyenv 3.12 (`lang_python=yes`, phase 04). Not pyenv global.
2. `pip install chatterbox-tts==<chatterbox_version>` — default `0.1.7`,
   override with `chatterbox_version=` in the host conf. The package pins
   torch/torchaudio 2.6.0, transformers, numpy<2; the default Linux torch wheel
   carries CUDA 12.4, so no system CUDA toolkit and nothing touches the driver.
3. `pip install -e $HOME/git/audiobook/chatterbook` — the engine's own package
   as an editable install (chatterbook/README.md: the editable install is the
   durable form; a hand-written `.pth` is what broke last time). Needs the
   audiobook container cloned (`clone_repos`) and bootstrapped.
4. Pre-warm the Turbo weights into `~/.cache/huggingface` so the first render
   is not a surprise pull. The hub repo id is read from the package
   (`chatterbox.tts_turbo.REPO_ID`), never copied here.

## Why opt-in

- ~5 GB of torch plus ~2 GB of weights; only a box that renders needs it.
- A worker's kokoro venv (`component_tts`) is the *desktop* clipboard tool and
  a different venv — the two never share (2026-09-16: a worker got 5.9 GB of
  kokoro it never runs).

## Setup-kit integration

- `component_chatterbox=yes` in `hosts/<hostname>.conf` (default `no`;
  `worker.example.conf` says yes). Provisioned by `07-components.sh`.
- `check` mode: venv / deps / chatterbook import (asked from `/`, so an
  uninstalled `./chatterbook` cannot answer) / GPU visible / weights cached.
  Changes nothing.
- `verify.sh`: fails by name when wanted and not importable; "not wanted"
  otherwise. `tests/test-chatterbox.sh` calibrates both.

## Notes

- GPU is report-only: Ampere+ and the cu124 wheel agree. A card the default
  wheel cannot drive is `component_tts`'s cu118 problem, not repeated here.
- Weights on Hugging Face may require accepting a license; if the pre-warm
  fails with a 401/403, set `HF_TOKEN` for the install and re-run.
- Size row: `manifests/sizes.conf` `component_chatterbox` — an estimate until
  the first real install is measured (`du -sh ~/.pyenv/versions/chatterbox
  ~/.cache/huggingface/hub/models--ResembleAI-*`).
