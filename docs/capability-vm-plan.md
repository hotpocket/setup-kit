# Plan — Disposable capability VMs + stampable Claude conduct

## Context

We keep handing Claude Code tools that **touch the local computer with real privilege**
— gstack headed-Chromium (drives a real browser, holds logged-in cookies), shell,
filesystem. Running those on a workstation with real credentials is a standing risk
(confused-deputy, SSRF amplifier, blast radius = your whole machine). The fix is the
same boundary Anthropic's self-hosted sandboxes and Browserbase draw: **isolate the
risky local-access tools inside a disposable, network-segmented Proxmox VM, expose them
over an authenticated API, and run a thin skill on dev machines that proxies to it.**
If something goes wrong, blow the VM away and re-stamp it.

setup-kit already knows how to stamp machines (idempotent, profile + numbered phases,
`lib.sh` primitives) and already creates VMs (`profiles/proxmox-host/04-create-workstation-vm.sh`).
This plan extends that. **The unclickbait service is the prototype** that informs the
hardware/software/observability requirements — it needs a headed browser render tier
(see `qualia/landry.bot`), which is exactly a capability-VM workload.

This plan has two layers. The **proximal tasks** (Part A) are standalone wins that also
de-risk the big build. The **capability-VM process** (Part B) is the main goal: a
repeatable "bring a new Proxmox VM online for a task" pipeline.

---

## Part A — Proximal tasks (do first)

### A1. Stampable Claude conduct kit ("how to behave on a new project")

**Problem:** Brandon re-instructs Claude Code how to conduct itself on every new project
(orient from Obsidian memory, available skills, rules of conduct). repo-story
(`~/git/repo-story`) has a working version of this but it's tangled with project-specific
pipeline content.

**The mechanism to copy (from repo-story):** `CLAUDE.md` is the session-start preamble
Claude auto-reads. It points at an Obsidian `vault/` for cross-session memory (read
`vault/sessions/Session Log.md` → latest recap → `vault/todos/<project>.md` at start;
offer `/vault recap` at end) and references the **canonical** `/vault` skill at
`~/.claude/skills/vault/SKILL.md`. No `.claude/settings.json` needed — conduct lives in
CLAUDE.md. The vault is a standard dir structure + frontmatter conventions, symlinked to
`~/Documents/AgentMemory/<project>` for cross-project discovery.

**Deliverable:** a `conduct` skill (or a `project-init` skill) that, when invoked in a
fresh repo, stamps the reusable scaffold:
- A `CLAUDE.md` template — conduct preamble with `<PROJECT>` placeholders: session
  orientation from vault, `/vault` usage, rules-of-conduct section, a "skills available
  here" pointer (gstack, vault, code-review, etc.).
- A `vault/` scaffold — `.obsidian/app.json`, `Home.md`, `sessions/Session Log.md`,
  `todos/<project>.md`, `projects/<project>/<project>.md`, with the frontmatter
  conventions and the symlink-to-`~/Documents/AgentMemory` step.
- `.gitignore` lines — commit vault notes + shared `.obsidian` config, ignore UI state
  (`workspace.json`, `plugins/`, `themes/`, `hotkeys.json`, `appearance.json`, `graph.json`).

**Split reusable vs project-specific** (from the exploration): CLAUDE.md *structure*,
vault scaffold, frontmatter conventions, `.gitignore` patterns are reusable. PLAN.md /
AUTORUN.md / prompts/ are project-specific and **not** part of the conduct kit (they're a
separate optional "pipeline scaffold").

**Home for the skill:** `~/.claude/skills/conduct/` (canonical, like `vault`), source-
controlled in its own repo or under setup-kit. Decide in A3.

### A2. Teach setup-kit about gstack (and the conduct skill)

setup-kit **already captures `~/.claude`** (`capture/04-dotfiles.sh`) and links
`.claude/settings.json` (`06-configs.sh`). What's missing is installing/refreshing the
**skills** a freshly-stamped machine should have.

**Deliverable:** a new phase `profiles/workstation/08-claude-skills.sh` (user-level,
runs after components), following the house idempotent pattern (source `lib.sh`,
`init_mode`, `do_or_say`, detect-then-act, log to `missing.log`). It ensures named
skills are present at `~/.claude/skills/<name>/`:
- `gstack` — symlink/install from `/media/brandon/WD_8T_2/git/ai-eval/gstack` (browse
  daemon binary at `…/gstack/browse/dist/browse`; the skill needs `bun` to build —
  gate on it).
- `vault` — canonical Obsidian memory skill.
- `conduct` — the A1 skill.
- (extensible list, driven by host conf, e.g. `claude_skills="gstack vault conduct"`).

**Host-conf knobs** (add to `hosts/example.conf`): `component_claude_skills=yes`,
`claude_skills="gstack vault conduct"`.

**Why this is also a building block:** the capability VM is just a machine that gets a
`claude` install + a *subset* of these skills. Getting the skills-install phase right on
the workstation profile means the VM profile reuses it.

### A3. Decisions blocking Part A

- Where do `conduct`/`gstack` skill sources live for distribution? (own repos under
  `~/git`, vendored in setup-kit, or a `skills/` dir in `.configs`?) — pick the place
  `08-claude-skills.sh` installs *from*.
- Does the conduct kit live in setup-kit or its own repo? (Lean: own repo
  `~/git/claude-conduct`, referenced by setup-kit — keeps setup-kit about *machines*,
  not *agent behavior*.)

---

## Part B — Capability-VM provisioning process

Goal: one repeatable pipeline that takes a *task spec* (hardware needs + software needs +
which capability tools) and brings a **disposable, observable, network-isolated** Proxmox
VM online, seeded and tested. unclickbait's render-tier need is the first instance.

### B0. Control-plane: how Claude reaches Proxmox

Today `04-create-workstation-vm.sh` assumes you're already on the Proxmox host running
`qm`. For a repeatable process driven from a dev machine, pick one (decision):
- **SSH to the Proxmox host**, run the capability-vm profile there (simplest, reuses
  existing `qm` scripts verbatim). Needs an SSH key to the host.
- **Proxmox REST API + API token** (`pvesh` / `https://<host>:8006/api2`), no shell on
  the host. Cleaner privilege boundary, more upfront wiring.

Recommendation: **SSH-to-host for v1** (reuses everything), revisit API tokens if we want
to drive it from CI or a non-LAN machine.

### B1. `profiles/capability-vm/` — the new profile

Mirror the proxmox-host pattern; numbered phases, `lib.sh`, doctor/install split.

- `00-vm-create.sh` — `qm create` parameterized from host conf, **no GPU passthrough by
  default** (browser render tier is headless; GPU only if a workload needs it). Smaller
  than the workstation: e.g. `capvm_cores=4`, `capvm_memory_mb=8192`, `capvm_disk_gb=40`.
  Cloud-init image instead of an ISO+manual-install so creation is unattended (decision:
  add a cloud-init Ubuntu image to Proxmox `local` storage; `qm set --ide2
  …cloudinit`, `--ciuser`, `--sshkeys`, `--ipconfig0`). **Put it on an isolated bridge
  / VLAN** (`--net0 virtio,bridge=vmbrISO,firewall=1`) with egress restricted — the VM
  should reach the internet for browsing but not the rest of the LAN.
- `01-base.sh` — minimal package set (`manifests/apt/capability-vm-base.list`:
  cli-system + dev-core subset, no desktop/media/games). Plus headless browser stack:
  Chromium/Chrome, Xvfb or a headless Wayland compositor, fonts.
- `02-capability-tools.sh` — install the capability tools themselves: gstack browse
  daemon (its value here = headed+stealth defeats bot walls, proven on Etsy), plus the
  authenticated **gateway** that exposes them (B3).
- `99-manual-checklist.md` — anything that can't be scripted.

**Note:** there is deliberately **no seed phase in the auto-run sequence.** Credential
seeding is a separate, human-gated action (B4) — `00`–`02` provision an *empty* VM with
no agent identity; the VM stays unauthenticated until Brandon grants it.

Reuse A2's `08-claude-skills.sh` logic (subset: just the tools the VM serves).

### B2. Host-conf for the VM (parameterize hardware + software)

Add to `hosts/example.conf` (or a per-VM conf):
```
capvm_vmid=210
capvm_name=cap-browser
capvm_cores=4
capvm_memory_mb=8192
capvm_disk_gb=40
capvm_bridge=vmbr1            # isolated network
capvm_gpu_passthrough=no
capvm_tools="gstack-browse gateway"
capvm_base_manifest=capability-vm-base
```
"Hardware requirements of the VM and its installed software for the task it's running"
= these knobs + the base manifest. A new task = a new conf + maybe a new manifest list.

### B3. The gateway (expose tools via an authenticated API/skill)

**Don't build a browser-automation API from scratch — gstack `browse` is already an HTTP
daemon with a bearer token on a fixed port.** v1 gateway = run the browse daemon, bind
its port to the isolated bridge, and put a thin auth layer in front (the same
Google-ID-token-or-shared-secret gate we built for unclickbait). The **dev-machine
client** is a `capvm` skill holding only `{vm_address, token}` (config pattern identical
to the PWA's `config.js`), proxying `goto/snapshot/screenshot/click/fill` to the VM.

Security requirements (non-negotiable, from the earlier assessment):
- Token/allowlist gate on the gateway — whoever calls it drives an authenticated browser.
- Network isolation — VM on its own bridge/VLAN, egress-restricted, no LAN reachability.
- **No crown jewels in the VM** — the only identity it ever holds is the scoped agent
  account (B4), seeded by a gated step; never Brandon's personal creds, AWS admin keys,
  prod SSH keys, or a password vault.

### B4. Agent identity + the gated credential seed

**The VM's identity is a dedicated agent account: `recursiveai@gmail.com`** — separate
from Brandon's personal accounts, scoped, and rotatable (change its password / re-mint
tokens to invalidate everything the VM holds). This is exactly the "scoped, rotatable,
no crown jewels" property the disposability story needs: a compromised or destroyed VM
costs us *one resettable agent account*, nothing of Brandon's.

**Provisioning and credential-copying are two separate acts, by design:**

- **Provisioning (B1 phases `00`–`02`)** is unattended and freely re-runnable — it stamps
  an *empty* VM with the tools but **no agent identity**. A freshly rebuilt VM comes up
  authenticated to nothing; it can't act as the agent until deliberately granted. (Nice
  property: a runaway/compromised provisioning pipeline can never exfiltrate the agent's
  creds, because they aren't present until the gated step runs.)

- **Seeding (separate gated tool, e.g. `bin/seed-agent-identity.sh <vm>`)** copies the
  `recursiveai@gmail.com` credentials into the VM and is **gated by a human authentication
  step — Brandon's YubiKey.** This is *not* a numbered phase and is *not* invoked by
  `bootstrap.sh … install`. It is its own command Brandon runs when present.

**Gating mechanism (decision — setup-kit already uses the YubiKey):** the agent
credentials live **encrypted at rest**, decryptable only with a YubiKey touch; copying =
decrypt-and-push in one gated motion, never leaving plaintext on the dev box or in logs.
Options:
- **`age` + `age-plugin-yubikey`** (FIDO2/PIV-backed age identity) — modern, simple, the
  encrypted bundle can even live in the repo since it's useless without the key.
- **GPG with the private key on the YubiKey** (PIN + touch) — reuses the exact mechanism
  `profiles/workstation/preamble-github-auth.sh` already drives.
- Either way: bundle is `age`/`gpg`-encrypted; `seed-agent-identity.sh` runs decrypt
  (triggers YubiKey touch) → push over the isolated SSH channel → wipe plaintext.

**State model under this split:**
- **Ephemeral (rebuilt, unattended):** OS, packages, binaries, caches, an empty Chromium
  profile.
- **Gated re-seed (`seed-agent-identity.sh`, YubiKey):** the `recursiveai@gmail.com`
  identity — OAuth/refresh tokens and/or browser session for that account, plus whatever
  task config needs it. Rebuild = re-stamp (auto) **then** one deliberate YubiKey-gated
  seed; never "log into 20 services by hand," but also never automatic.

**Concern to design around — Google login hardening:** automated/headless logins to a
Google account commonly trip security challenges. Prefer seeding **OAuth / refresh
tokens or app passwords** for `recursiveai@gmail.com` over raw password login, give the
agent account its own recovery setup, and expect to re-mint tokens periodically (the
rotation that makes the account safe to lose is the same lever that recovers from a
challenge).

### B5. Observability — "see what's going on" (Brandon asked to plan this)

Three layers, cheapest first:
1. **OS / boot level:** Proxmox **noVNC console** (`qm terminal` / web UI) for boot,
   cloud-init, and "is it even up." `qemu-guest-agent` (setup-kit's `00-identity`
   already installs it on KVM) gives the host the guest IP, lets it exec probes, and
   confirms liveness.
2. **Service level:** SSH in; tail `journalctl -u <gateway>` and the browse daemon log.
   Ship logs to a known path; optionally forward to the host. This is the primary
   headless-debugging channel.
3. **Visual / "what is the browser seeing":** the browse daemon's own `screenshot`
   command is the cheapest window into a headless browser — pull a PNG on demand, exactly
   how we verified the gate and Etsy this session. If we want a live desktop view of a
   headed session, add **wayvnc** (headless Wayland → VNC) or Proxmox **SPICE**; Claude
   reads frames via screenshots. Wire a `capvm screenshot` passthrough into the
   dev-machine skill so "show me what it's doing" is one command.

### B6. Bring-online + test sequence (the repeatable run)

1. `ssh proxmox` (or API token) — control plane up (B0).
2. `./bootstrap.sh capability-vm install` on the host → `00-vm-create` stamps the VM from
   conf (cloud-init, isolated bridge).
3. Wait for `qemu-guest-agent` to report an IP; SSH reachable.
4. Run `01-base` / `02-capability-tools` inside the VM (push profile in, or cloud-init
   pulls setup-kit + runs it — decision). VM is now tool-complete but **identity-less.**
5. **Gated seed (manual, YubiKey):** Brandon runs `seed-agent-identity.sh <vm>` →
   YubiKey touch → `recursiveai@gmail.com` creds land in the VM. Separate from steps 1–4.
6. **Verify** (mirror the unclickbait smoke pattern): gateway healthz; auth rejects no/bad
   token; a real `goto` + `screenshot` round-trips; the proven hard case (Etsy via
   headed-stealth) returns 200 and extracts. Capture a screenshot as the artifact.
7. Tear-down test: snapshot, destroy, re-stamp from scratch (steps 1–4, **unattended**),
   re-seed (step 5, **gated**), re-run verify — proves "blow it away" works *and* that the
   automatic path produces an identity-less VM while the gated path restores the agent.
   **This rebuild-and-verify loop is the real deliverable** — the VM isn't "done" until
   it's been destroyed and re-created green once, with the seed gate exercised separately.

### B7. unclickbait integration (closing the loop)

Once the gateway is live, unclickbait's render fallback (the tier we deferred) calls
**this VM** instead of Browserbase: extraction fails → ask the capability VM to render →
re-extract. In-house, no per-page SaaS cost, and it's the proven mechanism
(headed+stealth beat DataDome where every headless path 403'd).

---

## Open decisions (answer before building Part B)

1. **Tool scope of the VM:** browser only (v1), or shell/file access too? (Drives the
   gateway surface + base manifest.)
2. **YubiKey gating mechanism (B4):** `age` + `age-plugin-yubikey` vs GPG-on-YubiKey
   (latter reuses the existing `preamble-github-auth.sh` path). And where the encrypted
   `recursiveai@gmail.com` bundle lives (repo / removable media / SSM).
3. **Agent-credential form (B4):** OAuth/refresh tokens vs app password vs cookie/session
   export for `recursiveai@gmail.com` — pick the one that survives Google's automated-login
   challenges.
4. **Control plane (B0):** SSH-to-host vs Proxmox API token.
4. **Provisioning push vs pull (B6.4):** push the profile over SSH, or cloud-init pulls
   setup-kit and self-stamps.
5. **Skill source homes (A3):** where `conduct`/`gstack`/`capvm` skills live for install.

## Sequencing

A1 (conduct kit) and A2 (setup-kit skills phase) are independent and can land now — they
pay off on every project immediately and produce the skills-install machinery Part B
reuses. Part B follows once decisions 1–4 are answered, with unclickbait's render need as
the acceptance test. Each piece ships test-first / doctor-then-install per house style.
