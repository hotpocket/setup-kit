---
tags: [session]
type: session
concerns: [ops, infra]
audience: []
summary: "Consolidated 18 setup-kit T3 threads (Beast-VM + ai-3090) into the living WORKER thread. Nearly all were done; carried one todo here (pass store to both YubiKeys), one to .configs (hardcoded /home/brandon), one to the books repo (drop a one-off S3 lifecycle rule). Decisions kept below."
created: 2026-09-30
status: completed
projects: [setup-kit]
---

# Thread consolidation (setup-kit), 2026-09-30

Decisions and findings from archived threads that are not todos:

- **aws-cli v2 on Ubuntu 26.04 / Python 3.14** (v2.31.35 seen on Beast-VM): `s3api list-object-versions` and `list-objects-v2` exit with `badly formed help string` before any request (arg-doc parsing). `s3 ls/rm`, `delete-objects`, `get-bucket-*` work. Brandon: known, ignore for now. Relevant if a phase or doctor ever calls a list subcommand.
- **GitHub org for machine identity:** an org (`recurseai`) was created, but the decision was tokens on the personal account: a fine-grained PAT scoped to select repos is the isolation boundary regardless of owner. The org is reserved for a future GitHub App (per-VM short-lived tokens) or a second VM role that wants a team cap.
- **Tailnet shape (ai-3090 thread, abandoned by Brandon for "a different plan"):** stated intent was that isolated VMs never join or know the tailnet; only one privileged box fronts them. tailscale is no longer installed on ai-3090. A t3code thread cannot move between machines; the environment is chosen at thread creation.
- **t3code remote access on Beast-VM:** route chosen was loopback bind + `tailscale serve` (`t3 pair --tailscale`), which needs MagicDNS and HTTPS certificates enabled in the tailnet admin DNS page. `--label` names the client device in the server's connections list.
- **"Close the browser, it keeps running"** proven on ai-3090: agent runs in the lingering `t3code.service` (`Restart=always`, `OOMPolicy=continue`); a 30-sample foreground loop showed no gap across a browser shutdown. Unattended threads must be in full-access mode or they stall on approval prompts.
