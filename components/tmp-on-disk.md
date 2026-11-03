# /tmp disk and age policy

`tmp-on-disk.sh` remains the owner of both disk-backed `/tmp` and its cleanup
configuration. Its existing `tmp_on_disk` behavior and default are unchanged.

With **both** `tmp_on_disk=yes` and `tmp_age_rule=yes`, the whole owned file
`/etc/tmpfiles.d/tmp.conf` must contain exactly:

```text
D /tmp 1777 root root mM:10d
```

It must have mode 644. Check reports content/mode drift without sudo. Install
writes a staging file, installs it beside the target and renames it into place.
It starts the existing cleanup timer if needed; it never invokes `--clean`,
unmounts `/tmp` or deletes live scratch. A second install does not rewrite it.

With `tmp_age_rule` unset/no, preserve the existing q-rule content and separate
`/var/tmp` age. With `tmp_on_disk=no`, neither policy changes. This keeps Beast
and ai-3090's answer files on their existing path until they explicitly opt in.

Test: `bash tests/test-tmp-on-disk.sh`.
