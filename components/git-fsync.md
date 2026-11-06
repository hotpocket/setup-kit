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
Check mode reports drift without repair. `verify.sh` independently checks both
system values. No host-conf flag is needed. User or repository settings can
override the system default; these checks verify the system policy only.

To undo, remove both keys:

```sh
sudo git config --system --unset core.fsync
sudo git config --system --unset core.fsyncMethod
```

The next workstation or worker install restores the policy.
Calibration: `bash tests/test-git-fsync.sh`, using a temporary system config and
a sudo stub, without root or network access.
