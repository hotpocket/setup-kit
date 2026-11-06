# Muse Code

Meta's coding agent. Standard on worker VMs, opt-in on workstations with
`component_muse=yes`. Phase 07 is shared by both profiles.

- `~/.local/bin/muse`: launcher from `https://api.meta.ai/muse-launcher.sh`,
  fetched over HTTPS and validated before an atomic install. An executable
  launcher is left alone. It updates itself and downloads its binary beside
  itself on first use. The kit never runs it.
- `~/.config/muse/settings.json`: contributor mode stays off. The kit sets
  `contributor_mode_enabled=false`, preserving other keys and existing file
  permissions. New settings use mode 0600. Invalid JSON is reported and left
  unchanged.
- Existing `~/.t3/userdata/settings.json`: adds a missing `muse` provider with
  `driver=muse`, `enabled=true`. Other settings and existing Muse providers
  stay intact. A `settings.json.bak-<date>-muse` backup precedes each edit.
  Absent T3 settings are skipped.

Run `muse login` yourself. Meta's device flow prints a link for Brandon to
approve. The offline doctor checks only whether
`~/.config/muse/auth.json` is nonempty. It never reads credentials, contacts
Meta, or confirms that a session is still valid. Missing or empty auth gets
a login warning. Check mode reports drift without changing these files.

To uninstall, set `component_muse=no`, remove `~/.local/bin/muse` and the
binary it downloaded beside itself, and remove the `muse` provider entry
from T3 settings. Remove `~/.config/muse` only if you also want to discard
its login and settings. The kit does not uninstall or sign out for you.
