# mtga — opt-in component (workstation profile)

MTG Arena (Wizards of the Coast) running under Wine. Prefix `~/.wine`
(win64, reports Windows 10 build 18362). Install = wine runtime + WotC's
own bootstrap installer; the installer downloads the ~14 GB game client.

- Game dir once installed: `~/.wine/drive_c/Program Files/Wizards of the Coast/MTGA/`
- Launch: `~/bin/magic` (lives in `.configs`, not setup-kit) — `cd`s to the
  MTGALauncher dir and runs `wine MTGALauncher.exe`.

## Why it's wanted

It's the game. Default OFF — large (~14 GB), GUI, desktop-only.

## Install (install-only; the kit does NOT manage the 14 GB data)

1. Requires `group_wine=yes` (wine-stable + winetricks, `manifests/apt/wine.list`).
2. Fetch the bootstrap installer from WotC's stable URL — re-downloadable, no auth:
   `https://mtgarena.downloads.wizards.com/Live/Windows32/MTGAInstaller.exe`
   (the "Windows32" path is the universal bootstrapper; it installs the 64-bit
   client. ~37 MB; matches the copy historically kept in `~/Downloads`.)
3. `wine MTGAInstaller.exe` — GUI installer runs once, downloads the client
   into `~/.wine`. Not headless; needs a desktop session.

## Launcher desktop entry (auto-reconciled once MTGA.exe present)

Wine's `winemenubuilder` writes the Start-Menu shortcut to a *nested* path
(`~/.local/share/applications/wine/Programs/MTG Arena/MTG Arena.desktop`) that
GNOME's app grid won't surface, with a themed icon name (`FAC1_MTGALauncher.0`)
that needs an icon-cache rebuild — otherwise it shows as a generic gear.

When MTGA is installed, the component reconciles ONE clean launcher entry:
- writes `~/.local/share/applications/mtga.desktop` = the nested entry with its
  `Icon=` rewritten to the absolute hicolor PNG path (highest res available);
- sets `NoDisplay=true` on the nested original so only one MTGA shows;
- refreshes `update-desktop-database` + `gtk-update-icon-cache`.
Reconciled by content, so re-runs converge. Wine may rewrite the nested file on
launch (dropping `NoDisplay`); the next provision re-hides it.

## Idempotency

- Done = `~/.wine/drive_c/Program Files/Wizards of the Coast/MTGA/MTGA.exe`
  exists → component reports `ok`, then reconciles the launcher entry (above).
- `check` mode never downloads/runs the installer and never writes the entry —
  only reports presence and launcher-entry drift.
- The 14 GB client lives only in `~/.wine` (never in git, never re-provisioned).

## Setup-kit integration

- **OPT-IN** (`component_mtga=no` by default) — desktop game, not a dev need.
- Requires `group_wine=yes`; warn if wine is absent rather than installing it
  implicitly (that's the wine group's job).
- The `~/bin/magic` launcher is a user bin → belongs in `.configs`; the kit
  only doctor-checks it exists.

## Known caveat (NOT auto-handled — install-only by choice)

The launcher self-update can loop forever under Wine: newer launchers (≥1.0.124)
run PowerShell custom actions, and Wine ships only a stub `powershell.exe`, so
the self-update never commits → infinite "detects update → reload" loop. The
*install* succeeds; the loop only bites later when WotC ships a launcher newer
than the installed one. Manual durable fix (deliberately not baked into this
component): pin `MTGALauncher/launcherVersion`'s `"Version"` to `1.0.99999` and
`chattr +i` the file. Full diagnosis + recipe:
`~/ai/claude/LinuxBeast/2026-06-08-mtga-wine-launcher-update-loop.md`.
