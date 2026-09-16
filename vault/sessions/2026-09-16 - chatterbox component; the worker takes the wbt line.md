---
tags: [session]
type: session
concerns: [infra, ops, testing]
audience: []
summary: "The kit gained component_chatterbox: a pyenv 3.12 venv named chatterbox with chatterbox-tts 0.1.7 (torch 2.6.0+cu124), chatterbook editable, setuptools<82 (resemble-perth needs pkg_resources or the model dies on load), Turbo weights pre-warmed, a doctor probe that asserts the perth watermarker, verify.sh coverage and tests/test-chatterbox.sh. ai-3090 rendered its first chapters with it (RTF ~0.14x) and now runs the wbt line hourly (crontab: wbt update-cron :00, books sync-wbt :40), seeded from S3 and published to 1220 chapters. The wbt-side changes are in that repo's recap."
created: 2026-09-16
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-16 — chatterbox component; the worker takes the wbt line

## For Humans

- Every renderer on the audiobook line expects one Python environment named chatterbox, and nothing in the kit built it: a worker provisioned to render could not render a chapter. The kit now provisions it as an opt-in component, on by default for workers, and the doctor and verifier both check it.
- The first real render found a defect every import test missed: the model dies on load unless an old packaging helper is present. The doctor's probe now constructs what the model constructs, and the fix (a version pin) is on the install line with its reason.
- ai-3090 now runs the Weakest Beast Tamer pipeline hourly, seeded with the published audio from S3 and caught up to chapter 1220 tonight. The wbt repo's own recap has the pipeline-side detail; the one human action left is switching the workstation's copies of those cron lines off.

## Next Steps

- [ ] The books repo's `.venv` (boto3 for the publisher) was created by hand on ai-3090; the kit has no step for it. Decide whether `clone_repos` entries can declare a post-clone command, or the books repo grows a bootstrap the worker checklist names.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- Commits to read: bd0a05b (`components/chatterbox.md`, the 07-components block, verify.sh, `tests/test-chatterbox.sh`; mutants: import check always passing, unpinned package), 0d93463 (perth watermarker probe + `setuptools<82`, found by rendering one sentence on the GPU — check-mode probes cannot see this class: an optional import that becomes `None` inside a try/except).
- Measured on ai-3090: chatterbox venv ~5 GB, Turbo weights in `~/.cache/huggingface`, model load ~10 s, ~3.3 GB VRAM, RTF ~0.14x. `manifests/sizes.conf` row `component_chatterbox 7000M` is still the estimate; correct it with `du -sh ~/.pyenv/versions/3.12.14/envs/chatterbox ~/.cache/huggingface/hub/models--ResembleAI--chatterbox-turbo` (the `~/.pyenv/versions/chatterbox` path is a symlink, `du` on it reports 0).
- The worker's cron was written by hand (`crontab -` from a generated file; audiobook's `crontab --install` verb manages only its own tick block, which is deliberately NOT installed: the shelf books have no audio on this box). The audiobook container was bootstrapped (`scripts/bootstrap`: members cloned inside, `$GIT_HOME/{bookshelf,chatterbook}` symlinks) and its tests, chatterbook's and wbt's all pass under the chatterbox interpreter.
- Not provisioned on this box and not needed today: gstack, bun, a Chromium, `/etc/apparmor.d/playwright-chrome` (root). wbt's fetcher now asks the source plainly first and only needs those when Cloudflare arms its challenge; if that day comes, `component_claude_skills` plus the kit's AppArmor step (needs the user's sudo) is the path.
- `tests/test-aws-cli-v2.sh` case C still fails on this box for the reason in the earlier recap; unchanged.
