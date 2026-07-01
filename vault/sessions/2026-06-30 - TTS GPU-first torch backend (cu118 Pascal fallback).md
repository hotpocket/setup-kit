---
tags: [session]
type: session
concerns: [ops, infra]
audience: []
summary: "TTS (kokoro) was silently dead: torch 2.12+cu130's cuDNN dropped Pascal sm_61, so kokoro's CUDA pipeline init crashed and the server exit(0)'d — systemd saw success and never restarted. Fixed setup-kit to pick the torch backend by RUNNING a cuDNN op on the GPU: keep a working default wheel, fall back to cu118 torch 2.7.1 (last Pascal-supporting line, cuDNN 9.1) if it fails, pin CPU-only torch only if even cu118 can't drive the card or there's no usable GPU. verify.sh runs the same probe. GTX 1080 now runs kokoro on GPU. Committed ad01e3c."
created: 2026-06-30
status: completed
projects: [setup-kit]
branch: main
---

# Session — 2026-06-30 — TTS GPU-first torch backend

## Context
TTS (kokoro clipboard server, `tts-server.service`) was dead but not crashing —
`systemctl --user status` showed `inactive (dead)` with `code=exited,
status=0/SUCCESS`, so `Restart=on-failure` never fired. Task: diagnose and fix in
setup-kit (server left running per user; don't guess, prove it).

## Work Done (final state)
1. **Root cause** — the kokoro venv had `torch 2.12.0+cu130`, whose bundled cuDNN
   refuses GPUs with compute capability < 7.5. On this box's **GTX 1080 (sm_61,
   Pascal)** `KPipeline` init threw `cuDNN ... not compatible with devices with
   SM < 7.5`; the server's module-level fatal handler calls `cleanup()` →
   `sys.exit(0)`, so systemd recorded success and never restarted. The real trace
   lives in `/tmp/tts_clipboard.log`, NOT the journal (journal only shows the HF
   token warning + a clean exit).
2. **`profiles/workstation/07-components.sh` — GPU-first torch backend.** After
   the kokoro install, decide the torch wheel by *running a cuDNN op* on the GPU
   (`gpu_runs_kokoro()`: an `nn.LSTM(...).cuda()` forward + `synchronize` —
   kokoro's exact failing path), gated on `nvidia_wanted` (lib.sh):
   - usable GPU + probe passes → keep the default wheel (modern cards).
   - usable GPU + probe fails → install **cu118 torch 2.7.1**, re-probe → use GPU.
   - still fails, or no usable GPU → pin CPU-only torch (`pin_cpu_torch()`,
     `--force-reinstall --no-deps` against the cpu index).
3. **`verify.sh`** — replaced the "torch must be CPU-only" assertion with the same
   cuDNN-op probe: passes for a CPU build OR a CUDA build that actually drives the
   GPU; fails only for a CUDA build the card can't run (the silent-death case that
   still passes the import check).
4. **Live remediation** — installed cu118 torch 2.7.1 into the venv, verified the
   GPU LSTM op + a full `KPipeline` init/synth, restarted `tts-server.service` →
   `active`, "TTS service ready!" on GPU.

Commit (unpushed): `ad01e3c` (tts: GPU-first torch backend with cu118 Pascal fallback).

## Discoveries
- **Pascal sm_61 was dropped in torch 2.8 / cuDNN 9.12** (Maxwell/Pascal/Volta
  removed from cu128/cu129 builds). The **cu118 wheel line through torch 2.7.1**
  still ships sm_61 kernels + a Pascal-capable cuDNN (installs `nvidia-cudnn-cu11
  9.1.0`). So an old GPU CAN run kokoro — it just needs that wheel; CPU is a last
  resort, not the answer.
- **cu118 torch 2.7.1 is NOT self-contained** — it depends on `nvidia-*-cu11`
  runtime packages (`libcudart.so.11.0`, `libcublas`, cuDNN). `--no-deps` fails at
  import. Install *with* deps from the cu118 index; the general python deps
  (sympy/networkx/…) must already be present because that index doesn't mirror
  PyPI — hence installing after the kokoro step in the same phase.
- **The import check is not enough.** `import kokoro,soundfile,sounddevice`
  succeeds on the broken CUDA build; only executing a cuDNN op on the device
  surfaces the incompatibility. Detection must run a real op, not read compute-cap.
- kokoro pins no torch version (`Requires: ... torch`), so downgrading to 2.7.1 is
  safe.

## Decisions
- **Detect by execution, not heuristic.** Run a cuDNN op and let the result pick
  the wheel — reverses this session's own earlier CPU-pin-everywhere approach
  (which worked but sacrificed GPU accel on every card).
- **GPU-first, CPU last.** Modern cards keep the fast default wheel; Pascal-era
  cards get cu118; only genuinely-unusable GPUs (or none) fall to CPU.
- Keep the probe identical in `07-components.sh` and `verify.sh` so the doctor and
  the installer agree on "can this run."

## Next Steps

### Loose ends (cleanable now)
- (none new this session.)

### Needs dedicated focus
- (none new.) Pre-existing TODO stands: verify a fresh `bootstrap.sh workstation
  install` wires phase 08 + .configs end to end — unaffected by this change.

## Related
- [[2026-06-29 - TTS client controls + VLC-to-sounddevice + systemd]] — the prior
  TTS session (VLC→sounddevice, systemd unit, component_tts provisioning) this
  builds directly on.
