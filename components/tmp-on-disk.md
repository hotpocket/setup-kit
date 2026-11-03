# /tmp disk and age policy

`tmp-on-disk.sh` owns disk-backed `/tmp` and its cleanup configuration.
`tmp_on_disk` behavior and defaults are unchanged.

With both `tmp_on_disk=yes` and `tmp_age_rule=yes`, the whole owned file
`/etc/tmpfiles.d/tmp.conf` contains one line, mode 644:

```text
D /tmp 1777 root root <age>
```

The host-conf key `tmp_age` supplies the complete age field. If unset or empty,
`TMP_AGE_DEFAULT` in `manifests/tmpfiles.conf` supplies it. The component and
independent verifier read that same data file. Its current value is `mM:10d`;
existing hosts keep the current rule. No host answer file is changed here.

The proposed alternative is `tmp_age=bcmBM:10d`, pending Brandon's decision.
For files it considers birth, status change and modification times. For
directories it considers birth and modification times. Both omit access time,
so reading old files does not keep them alive. Tar extraction and `rsync -a`
can preserve mtime but create fresh birth/ctime, which protects new extractions
under the proposed rule. Directory ctime is omitted because cleanup itself
changes it when deleting children.

Where statx cannot report birth time, systemd 259 gives that timestamp no
protection. The proposed rule then uses ctime and mtime for files, and mtime
alone for directories. Freshly extracted files still have fresh ctime. A fresh
empty directory with preserved old mtime can expire without birth-time support.
There is no automatic policy substitution. See the [systemd 259 age rules](https://www.freedesktop.org/software/systemd/man/259/tmpfiles.d.html#Age).

Check reports content/mode drift without privileged writes. Install stages the
file beside the target and renames it into place. It starts the cleanup timer
if needed; it never invokes `--clean`, unmounts `/tmp` or deletes live scratch.
A second install does not rewrite matching content.

With `tmp_age_rule` unset/no, the existing q-rule and separate `/var/tmp` age
remain. With `tmp_on_disk=no`, neither policy changes.

Tests:

- `test-tmp-on-disk.sh`: existing install/check behavior.
- `test-tmp-age-policy.sh`: host override, shared default and verifier agreement.
- `test-tmp-clean-behavior.sh`: documents the current rule's deletion behavior.
- `test-tmp-age-clean.sh`: real cleanup in private ext4 roots, with statx birth
  times and real tar extraction. Exact `10d` fields test fresh extraction. A
  private `2s` age with unchanged selectors tests old birth/ctime expiry and
  fresh reads without altering the clock or faking timestamps. Normal file APIs
  cannot backdate birth/ctime. The test uses the checkout's `logs/` filesystem
  by default, or `TMP_AGE_SCRATCH`; it fails with a remedy if ext4 birth-time
  support is absent. It never cleans host `/tmp`.
