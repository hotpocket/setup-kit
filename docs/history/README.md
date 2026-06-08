# History

setup-kit began as a one-shot migration kit for moving a single Ubuntu
workstation to new hardware — capture the old box, restore onto the new one.
It was reframed into a reusable, profile-based provisioner: run it against a
fresh Linux install and it converges the machine to a known-good state,
idempotently. The capture tooling survives as the manifest-refresh step
(`capture/`).

Proven on bare-metal Ubuntu 24.04 (X11) and 26.04 (Wayland).
