---
tags: [session]
type: session
concerns: [ops, infra]
audience: []
summary: "New opt-in component_whisper: faster-whisper (whisper-ctranslate2 via pipx, CUDA as venv-local pip wheels — no system toolkit, large-v3 pre-warmed) turns yda/ydv yt-dlp audio/video into searchable .srt; verified end-to-end on the 3090. Fixed lib.sh has_nvidia/nvidia_wanted: grep -q under pipefail SIGPIPEs the producer and intermittently reported NO GPU (gated driver install + tts GPU path). 04-languages now installs deno (yt-dlp deprecated YouTube extraction without a JS runtime). .configs gained bin/transcribe + ydat/ydv."
created: 2026-07-03
status: completed
projects: [setup-kit]
branch: main
---

# whisper transcription component + lib.sh pipefail fix

- `components/whisper.md` + `07-components.sh`: opt-in `component_whisper` —
  `whisper-ctranslate2` (faster-whisper/CTranslate2) via pipx; CUDA runtime as
  venv-local pip wheels (`pipx inject nvidia-cublas-cu12 nvidia-cudnn-cu12==9.*`),
  NO system CUDA toolkit; model (`whisper_model`, default large-v3 ~3 GB)
  pre-warmed via `faster_whisper.download_model(name, local_files_only=True)`
  cache probe (offline-safe, resolves distil naming). Flags in example.conf +
  LinuxBeast2.conf (=yes). Commits `41e8217`, `c2bc24b`.
- Engine choice: on NVIDIA, faster-whisper beats whisper.cpp (~12× vs ~8×
  realtime large-v3, same weights/accuracy); whisper.cpp remains the
  CPU/Apple-Silicon champion. Whisper reads video containers directly (PyAV).
- **lib.sh fix**: `has_nvidia`/`nvidia_wanted` used `grep -q` in pipelines under
  `set -o pipefail` — grep's first-match exit SIGPIPEs the producer, pipeline
  "fails", kit intermittently saw NO NVIDIA GPU (gated 02's driver install and
  the tts GPU path). Fixed: grep reads to EOF (`>/dev/null` instead of `-q`).
  Pattern is audit-worthy elsewhere.
- `04-languages.sh`: installs deno (official script → `~/.local/bin`) — yt-dlp
  deprecated YouTube extraction without a JS runtime. Commit `5e38db0`.
- `.configs` (`f22f240`, `cad2520`, `5626afd`): `bin/transcribe` — srt-only
  output (txt/vtt/tsv/json = clutter; srt is greppable + jump-to-timestamp;
  player overlay is a toggle, not a file problem); exports `LD_LIBRARY_PATH`
  into the venv's nvidia wheel dirs (namespace packages: `__path__[0]`,
  `__file__` is None). `ydat` (audio) / `ydv` (video) = download + transcribe.
- Verified: phase 07 check all-OK; real 38-min video transcribed on the 3090.

## Next steps

- Audit remaining `grep -q` pipelines under lib.sh's pipefail (~15 min, mechanical).
- Fresh-box install verify (existing TODO) now also covers whisper + deno.
