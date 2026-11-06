# Git fsync

Every workstation and worker gets these system Git settings through phase
`00-identity.sh`, including Beast, dev, ai-3090 and the control hub on VM 103:

```ini
[core]
    fsync = committed
    fsyncMethod = fsync
```

In the 2026-11-06 power-cut series `series-20261106T083614Z`, all three cuts
left empty loose objects in both the working repo and bare hub on the test
clone. `HEAD` became unreadable and `git fsck` failed. Git's default does not
fsync loose objects and refs. This policy asks Git to fsync committed data and
references before reporting success. It still depends on storage honoring fsync.
The original evidence is on dev in `~/powercut-logs/series-20261106T083614Z/`.

The installer uses `git config --system`, preserves unrelated settings, and
writes only missing or different values. Correct values need no sudo or writes.
No host-conf flag is needed. If a wrong system value comes from an include,
the installer names that file and the required setting. It leaves that key
alone in both files. Identity setup still runs, then the phase exits nonzero.

The doctor and independent `verify.sh` also read effective values with
`--show-origin` for the invoking user, including HOME/XDG settings. They fail
if `core.fsync` lacks loose-object, pack or reference coverage, or if
`core.fsyncMethod` differs from `fsync`. `added`, `all` and explicit component
lists with the required coverage pass. Coverage follows Git 2.53's
[parser](https://github.com/git/git/blob/v2.53.0/environment.c) and
[component definitions](https://github.com/git/git/blob/v2.53.0/write-or-die.h).
Unknown list tokens fail closed.

Only when component_git_hub=yes, check each existing bare repo listed in git_hub_repos at git_hub_root/<basename>.git, with git_hub_root defaulting to /srv/git. An optional :clone/path suffix does not change the bare repo name. In each repo context, audit system includes and persistent effective values for the configured git_hub_user (default git). That user's passwd home sets the global and XDG config locations (HOME and HOME/.config). Remove caller transient Git environment first, including command overrides and HOME or global config overrides, and keep a separate neutral caller environment check. When the caller UID differs from that writer, both the verifier and the doctor attempt a read-only noninteractive probe, sudo -n -H -u <writer> -- env -i ..., with the environment stripped, running Git --show-origin in the managed bare-repo context. The git-shell writer need not run the verifier interactively. Report FAIL not checked and never pass only if the probe is unavailable, the writer identity cannot be validated, or the writer home or config cannot be read. In the doctor, remaining identity setup still runs and the phase keeps the failure. Never rewrite an offending repo, include, or global file. Local overrides in other repos stay out of scope.

To undo, remove both keys:

```sh
sudo git config --system --unset core.fsync
sudo git config --system --unset core.fsyncMethod
```

The next workstation or worker install restores the policy.
Calibration: `bash tests/test-git-fsync.sh`, using a temporary system config and
a sudo stub, without root or network access.
