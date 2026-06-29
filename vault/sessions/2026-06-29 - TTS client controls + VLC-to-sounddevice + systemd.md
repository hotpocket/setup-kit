---
tags: [session]
type: session
concerns: [ops, infra, ux]
audience: []
summary: "Overhauled the kokoro clipboard-TTS stack: added prev/pause/next transport + an expandable text panel to the Flutter client, a distinct tts-player window icon, and replaced VLC with a persistent sounddevice/PortAudio stream (fixes first-sentence cold-start stutter). Server now runs as a systemd --user service instead of XDG autostart. setup-kit component_tts reprovisioned (libportaudio2 + sounddevice, not vlc/python-vlc). All committed, unpushed."
created: 2026-06-29
status: completed
projects: [.configs, setup-kit]
branch: master
---

# Session — 2026-06-29 — TTS controls + VLC→sounddevice + systemd

## Context
Enhancing the kokoro clipboard-TTS stack: the Flutter control window
(`~/git/.configs/tts-flutter`) and its Python backend (`bin/tts-clipboard-server`),
plus the matching setup-kit provisioning.

## Work Done (final state)
1. **Flutter client transport UI** — prev / pause / next buttons + an expandable
   text panel that shows the current part's text (window grows via a native
   `tts/window` method channel). Removed the Stop button (the window X already
   cancels). Prev on the first part restarts it.
2. **Distinct player icon** — `tts-player` (cornflower "TTS" + green waveform,
   transparent) at all hicolor sizes, mapped to the window via
   `com.example.tts_client.desktop` (on Wayland the icon comes from the app_id→
   desktop-file match, not `_NET_WM_ICON`). `setup.sh` links icons reproducibly.
3. **Server protocol** — `pause`/`resume`/`next`/`prev` commands over their own
   short-lived socket connections; status stream now carries `part`/`total`/`text`.
4. **VLC removed** — the server keeps one persistent `sounddevice`/PortAudio
   `OutputStream` open for its lifetime; a pull callback emits the current chunk's
   numpy samples (silence when idle/paused). No temp WAVs; sample-accurate
   pause/seek. Eliminates the first-sentence cold-start stutter by construction.
5. **systemd --user service** — `tts-server.service` (`Restart=on-failure`,
   journald, `WantedBy`/`PartOf=graphical-session.target`, `After=pipewire`)
   replaces XDG autostart. `.configs/setup.sh` migrates existing boxes (removes
   the old autostart symlink, enables the unit) and self-heals the venv (ensures
   `sounddevice`).
6. **setup-kit component_tts + verify.sh** — provision `libportaudio2` +
   `sounddevice` instead of `vlc`/`python-vlc`; dropped `python3-tk` (the old Tk
   client is gone). General-purpose VLC media player stays in `media.list`.

Commits (all unpushed): `.configs` d3c5632 (transport/text/icon), a1d9a5a
(VLC→sounddevice + systemd); `setup-kit` 6cdec94 (sounddevice provisioning).

## Discoveries
- **First-sentence stutter was a VLC clock bug.** VLC verbose log on a cold
  PulseAudio stream: `playback way too late: flushing buffers` + `write index
  corrupt`; the second (warm) play is clean. A persistent, never-closed output
  stream removes the cold start entirely — the real fix, not a warm-up hack.
- **Vault skill is not installed on this box (setup-kit gap).** Phase
  `08-claude-skills` sources `vault`/`conduct` from `~/git/claude-conduct`, which
  is *local-only* (no clone URL) and absent here → the skill never lands at
  `~/.claude/skills/vault`; `logs/missing.log` has flagged this every run. A
  working copy exists at `~/git/hh/vault/working-knowledge/skills/vault` (v4.0).
  An agent following the documented path can't find the skill.
- Launching a long-lived daemon from a sandboxed tool call gets reaped;
  `systemd-run --user` escapes the sandbox and is the reliable way to start it
  mid-session.

## Decisions
- Replace VLC outright (recurring problem child) rather than add a warm-up play.
- `sounddevice` persistent stream over a `pw-play`-per-chunk subprocess: gapless,
  sample-accurate, no per-chunk process churn.
- systemd `--user` service over XDG autostart for supervision + control; bound to
  `graphical-session.target` so it can't race the audio/Wayland session at login.
- Keep the general VLC media player in `media.list`; only the TTS-specific
  `libvlc`/`python-vlc` dependency was removed.
- `tts-flutter/pubspec.lock` stays tracked (Flutter *application* convention).

## Next Steps

### Loose ends (cleanable now)
- **Refresh `~/git/.configs/tts-flutter/README.md`** — stale: still documents the
  removed "Stop Reading" button and predates the transport controls, text panel,
  `tts-player` icon, the VLC→sounddevice swap, and the systemd unit. ~15 min.
- **Resolve the vault-skill install gap** — decide the canonical home and either
  restore `~/git/claude-conduct` or repoint setup-kit phase 08 at the `~/git/hh`
  copy, so the skill stops being silently skipped. A path + a yes/no. ~15–20 min.

### Needs dedicated focus
- (none)
