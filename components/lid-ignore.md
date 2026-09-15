# lid-ignore — laptop as a node (workstation profile)

A laptop that runs with the lid shut — reached over ssh, driving a dock, or
just parked as a build box — must not suspend when the lid closes. logind's
default is `suspend` for all three lid states (on battery, on external power,
docked), so a fresh install of the same hardware goes to sleep the moment the
lid is closed and drops off the network.

This is a **role** choice, not a hardware fact: the same ThinkPad is a normal
laptop on one day and a node on another. So it is opt-in per host, and the
component refuses to act on anything `hostnamectl chassis` does not call a
`laptop` or `convertible` — on a desktop or VM the drop-in is noise.

## What it does

Writes one drop-in, reconciled by content:

```
/etc/systemd/logind.conf.d/10-lid-ignore.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

All three, deliberately: the plain handler alone still suspends on AC or when
docked. Applied with `systemctl reload systemd-logind` — never `restart`,
which tears down the graphical session (systemd ≥ 254 re-reads `logind.conf.d`
on reload; Ubuntu 26.04 ships 259).

Reversal: `sudo rm /etc/systemd/logind.conf.d/10-lid-ignore.conf && sudo
systemctl reload systemd-logind`, or flip the flag to `no` (the phase then
leaves the file alone — it reports disabled and does not remove).

## Setup-kit integration

- Flag: `component_lid_ignore` (default **no** — opt-in).
- Installed by `profiles/workstation/07-components.sh`; idempotent; check mode
  reports missing/drifted/in place.
- Verify: `verify.sh` asks logind itself over D-Bus
  (`busctl get-property … HandleLidSwitch*`) — the file can exist while the
  running logind has not picked it up.
- Calibration: `tests/test-lid-ignore.sh` (stubs `hostnamectl` and `busctl`).

## History

Migrated 2026-09-14 from the one-off `setup` repo (`etc/systemd/logind.conf.d/10-node.conf`,
same content, installed by hand with `systemctl restart`). That repo predates
the setup-kit / .configs split and this was its only content not already
covered here.
