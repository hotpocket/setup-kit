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
7. **Vault/conduct skill now installs.** `claude-conduct` was pushed to
   `git@github.com:hotpocket/claude-conduct.git` and cloned to `~/git/claude-conduct`;
   setup-kit phase `08-claude-skills` now has the real clone URL (was local-only),
   so fresh boxes clone it and symlink `vault`/`conduct` into `~/.claude/skills/`.
   Ran the phase here — both skills linked and resolvable.

Commits (all unpushed): `.configs` d3c5632 (transport/text/icon), a1d9a5a
(VLC→sounddevice + systemd); `setup-kit` 6cdec94 (sounddevice provisioning),
d132745 (claude-conduct remote so vault/conduct skills clone on fresh boxes).

## Discoveries
- **First-sentence stutter was a VLC clock bug.** VLC verbose log on a cold
  PulseAudio stream: `playback way too late: flushing buffers` + `write index
  corrupt`; the second (warm) play is clean. A persistent, never-closed output
  stream removes the cold start entirely — the real fix, not a warm-up hack.
- **The vault skill wasn't installed because `claude-conduct` had no remote.**
  Phase `08-claude-skills` registered it local-only, so on a box without the repo
  the skill silently never landed (flagged in `logs/missing.log` every run).
  Fixed this session (repo now on GitHub + phase 08 has the URL).
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

### Needs dedicated focus
- (none)
