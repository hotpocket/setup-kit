# Proxmox conversation — sandboxing a local agentic coder (2026-06-29)

Continuation of [`capability-vm-plan.md`](capability-vm-plan.md) (disposable, network-
segmented Proxmox VMs for risky local-access tools). This note captures the **new bits**
from the 2026-06-29 session: the local-LLM coding agent that triggered it, and the
GPU-passthrough question for this specific box (LinuxBeast2).

## Trigger

Set up a local coding stack on LinuxBeast2:
- `ollama` serving **qwen3-coder:30b** (MoE, 3B active) on the RTX 3090 — benchmarked
  **~187 tok/s**, 100% GPU, 32K ctx. Replaced the old codellama 7B as the `wat` model.
- **opencode** (open-source Claude-Code-style terminal agent) installed and wired to the
  local model via `~/.config/opencode/opencode.json` (Ollama OpenAI-compat endpoint
  `http://127.0.0.1:11434/v1`). Verified end-to-end.

opencode "sees tools" (can edit files / run commands). **Brandon will not give a local
model write access to the real system** → wants it sandboxed. His stated path was:
turn LinuxBeast2 into a Proxmox host with GPU passthrough so the 3090 can be released to
whichever VM needs it.

## Key insight — the agent does NOT need the GPU; only Ollama does

`opencode` is just an HTTP client: it POSTs prompts to `127.0.0.1:11434` and gets text
back. The GPU is used by **Ollama (the inference server)**, not the agent harness.

Therefore **sandboxing the agent does not require Proxmox or GPU passthrough.** The two
goals are decoupled:

1. **Sandbox the agent (the actual security goal):** isolate `opencode` — give it only a
   bind-mounted project dir + network access to the Ollama endpoint. It physically can't
   touch the host FS/system. A rootless container (already provisioned:
   `component_docker_rootless=yes`) does this in minutes, fully reversible, zero risk to
   the daily-driver install. Ollama keeps the GPU exactly where it is.
2. **Proxmox + reassignable GPU (a separate, larger capability goal):** a VM lab where the
   3090 can move between VMs. Legit on its own merits (this is what `capability-vm-plan.md`
   is about), but it is NOT a prerequisite for goal #1.

## Hardware findings — Proxmox passthrough IS viable on this box

| Prereq | Status |
|---|---|
| dGPU to pass | NVIDIA RTX 3090 (`01:00.0`, GA102) |
| Host display GPU | **AMD Radeon iGPU** in the 9950X (`79:00.0`, Granite Ridge) — host boots on iGPU, 3090 frees for VMs. This is the detail that makes single-dGPU passthrough clean. |
| IOMMU | **ON now** — 32 groups present |
| Virt ext | AMD-V (`svm`) present |
| Tooling | setup-kit `profiles/proxmox-host/` exists: `01-grub-iommu`, `02-vfio-bind`, `03-zfs-tune`, `04-create-workstation-vm`, `05-nested-virt` — **reviewed-but-unrun** |

"Release the GPU to other VMs on demand" = **one VM at a time**: stop VM-A → detach 3090
→ start VM-B with it. NOT simultaneous sharing (consumer 3090 has no vGPU/MIG). Proxmox
handles the stop/start reassignment fine.

## The cost / risk

LinuxBeast2 **is the daily driver** (boots `/dev/mapper/ubuntu--vg-ubuntu--lv`). Full
Proxmox conversion = rebuild the box into a hypervisor and demote the workstation to a VM.
Days of work, runs reviewed-but-unrun code, biggest stability hit on the table — notable
given Brandon's stability-first ethos.

## Open decision (unresolved — to discuss offline)

Three paths, not yet chosen:

- **A. Container now (recommended for the stated goal):** jail `opencode` in rootless
  Docker/Podman; keep bare-metal. Solves the security goal today, reversible.
- **B. Full Proxmox rebuild of this machine:** destructive, days, the big lab capability.
- **C. Proxmox on a separate/new NVMe:** keep current Ubuntu bootable, stage the migration
  gradually. Needs another drive.

Second axis to resolve: is Proxmox really *for* sandboxing the agent (then A is enough and
B/C are over-engineering), or is the agent just the trigger for a VM lab Brandon wants
regardless (then B/C are justified on their own merits per `capability-vm-plan.md`)?

## Recommendation

Do **A now** (sandbox opencode in a container — cheap, correct, reversible), and treat
Proxmox (B/C) as the deliberate, separately-planned project it already is in
`capability-vm-plan.md` — not something to rush because of the agent. The agent's
filesystem risk is fully contained by a container; the GPU never needs to move for it.

## Pointers

- Local stack commits this session: setup-kit `097df80` (wat→qwen3-coder), `.configs`
  `344ac94` (alias). opencode install is user-level only (not in setup-kit yet).
- Bigger plan: [`capability-vm-plan.md`](capability-vm-plan.md).
- Proxmox scripts: `profiles/proxmox-host/` (+ its `99-manual-checklist.md`).
