---
name: 2026-06-29-local-llm-opencode-proxmox
description: Session log — local LLM coding stack (ollama/qwen3-coder + opencode) and the Proxmox-sandbox decision
date: 2026-06-29
tags: [session, ollama, opencode, proxmox, gpu-passthrough, local-llm]
---

# Session — 2026-06-29 — Local LLM coding stack + Proxmox sandbox question

## What we did

- Researched running **GLM-5.2** locally (744B MoE / 40B active). Verdict: not feasible on
  LinuxBeast2 (64GB RAM + 24GB 3090) — smallest quant needs ~223–239GB. Even page-file /
  Gen5 NVMe / Strix Halo (128GB) / 256GB RAM paths are too slow or too small; it's an
  API job. Explored the RAM-upgrade math (AM5: 2-DIMM > 4-DIMM for speed; 64GB stick max;
  256GB only config that fits GLM-5.2, ~6–9 tok/s, ~$2.7k+ RAM at 2026 shortage prices).
- Confirmed **ECC is working** (SECDED active, amd64_edac bound, 0 errors). Brandon runs
  ECC deliberately — stability-first. Decided NOT to add an ECC check to setup-kit
  (auto-detects, hardware-dependent).
- Picked the right **local coding model**: **qwen3-coder:30b** (MoE 3B-active) on the 3090.
  Benchmarked **~187 tok/s** vs old codellama 7B **~159 tok/s** — faster AND far stronger
  AND 2x context. Repointed the `wat` alias + setup-kit to it.
- Reviewed setup-kit core (lib/bootstrap/verify) with qwen3-coder vs me; qwen produced
  cosmetic/false-positive findings, I found + fixed 6 real ones (commit `9eb93e4`).
- Installed **opencode** (terminal agent) wired to local qwen3-coder. Works, sees tools.

## The pivot (unfinished — to continue)

Brandon won't give a local model write access to the real system → wants it **sandboxed**,
and proposed converting LinuxBeast2 to a **Proxmox host with reassignable 3090 passthrough**.

**Key insight:** the agent (opencode) doesn't need the GPU — only Ollama does. So
sandboxing the agent = container around opencode; Proxmox/passthrough is a *separate*
bigger goal, not a prerequisite. Hardware is viable for Proxmox (iGPU for host + 3090 for
VMs, IOMMU on, AMD-V, setup-kit proxmox-host profile exists but reviewed-but-unrun), but
it's a destructive rebuild of the daily driver.

Decision deferred to offline discussion. Full detail + the 3 paths (container now / full
Proxmox rebuild / Proxmox on separate disk) in [`docs/proxmox_conversation.md`].

## Commits this session (NOT pushed — Brandon pushes)

- setup-kit `9eb93e4` — harden lib/bootstrap/verify (6 fixes)
- setup-kit `097df80` — wat → qwen3-coder:30b (single `ollama_model` var)
- `.configs` `344ac94` — `alias wat='ollama run qwen3-coder:30b'`
- (this session also adds `docs/proxmox_conversation.md` + this session file)

## Open threads / next

- [ ] Decide sandbox path (container vs Proxmox) — see proxmox_conversation.md
- [ ] If container: jail opencode in rootless Docker (project bind-mount + Ollama net only)
- [ ] If Proxmox: this ties into `docs/capability-vm-plan.md` (disposable capability VMs)
- [ ] opencode is user-level only; not yet a setup-kit component
