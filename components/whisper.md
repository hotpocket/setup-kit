# whisper — opt-in component (workstation profile)

Speech-to-text for the audio archive: `yda` (yt-dlp bestaudio→mp3 alias in
`.configs`) downloads the audio, this turns it into searchable text. Engine is
**faster-whisper** (CTranslate2) via the `whisper-ctranslate2` CLI — a drop-in
replacement for the openai `whisper` command.

- CLI: https://github.com/Softcatala/whisper-ctranslate2
- Engine: https://github.com/SYSTRAN/faster-whisper (MIT)

## Why faster-whisper, not whisper.cpp

- On NVIDIA, CTranslate2 beats whisper.cpp's CUDA path (~12× vs ~8× realtime
  for large-v3, less VRAM, identical weights = identical accuracy).
  whisper.cpp is the champion on CPU/Apple Silicon — not here.
- No system CUDA toolkit: cuBLAS + cuDNN ship as pip wheels *inside the pipx
  venv* (`pipx inject … nvidia-cublas-cu12 nvidia-cudnn-cu12`). Nothing
  touches the system driver stack — stability-first.

## Why it's opt-in (not default)

- The model is the real cost (large-v3 ≈ 3 GB into `~/.cache/huggingface`).
- Only useful on boxes doing audio archiving; CPU-only boxes would crawl.

## Install

1. `pipx install whisper-ctranslate2` — isolated venv, `~/.local/bin` CLI
   (pipx comes from `manifests/apt/dev-python.list`).
2. If `nvidia_wanted`: `pipx inject whisper-ctranslate2 nvidia-cublas-cu12
   'nvidia-cudnn-cu12==9.*'` — the CUDA runtime, venv-local.
3. Pre-download the model (install mode only) so first real use is instant.

## Setup-kit integration

- **OPT-IN** — `component_whisper=yes` in `hosts/<hostname>.conf` (default
  `no`). Provisioned by `profiles/workstation/07-components.sh`.
- `check` mode: reports CLI / CUDA wheels / model cache, changes nothing.
- Model defaults to `large-v3` (best accuracy for archives). Override with
  `whisper_model=distil-large-v3` in the host conf for ~6× faster
  English-only.
- Usage glue lives in `.configs` (two-repo rule): `bin/transcribe` (sets
  `LD_LIBRARY_PATH` to the venv's nvidia wheel dirs, writes .txt/.srt/… next
  to each audio file) and the `ydat` alias (`yda` + transcribe in one step).

## Notes

- CTranslate2 dlopens libcublas/libcudnn — the wrapper exports
  `LD_LIBRARY_PATH` pointing into the venv's `nvidia/*/lib` dirs; without it
  a CUDA run dies with "libcudnn_ops not found". CPU fallback always works.
- Model cache is `~/.cache/huggingface/hub/models--Systran--…`; verified via
  `faster_whisper.download_model(name, local_files_only=True)` (offline-safe,
  handles the distil naming difference).
- VRAM: large-v3 fp16 ≈ 4.7 GB, int8 ≈ 2.5 GB — trivial for the 3090.
