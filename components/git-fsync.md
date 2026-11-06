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

On a hub box with `component_git_hub=yes`, both checks inspect the existing
bare repos named by `git_hub_repos`, at `<git_hub_root>/<basename>.git`.
The root defaults to `/srv/git`; `:clone/path` does not change a bare repo's
name. Local overrides and includes in those repos must satisfy the same
coverage. Checks use the invoking account and never rewrite its overrides.
The doctor names repos not initialized yet; verification fails on them.
Other repositories' local overrides, including the incidental checkout, are
outside these checks. Another account's globals need a check as that account.

To undo, remove both keys:

```sh
sudo git config --system --unset core.fsync
sudo git config --system --unset core.fsyncMethod
```

The next workstation or worker install restores the policy.
Calibration: `bash tests/test-git-fsync.sh`, using a temporary system config and
a sudo stub, without root or network access.
