#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools component_oom_zram=yes swap_policy=zram-only
# Cloud image has zram generator but no oomd. Installed boxes already have both.
cat > "$TMP/bin/dpkg" <<'SH2'
#!/bin/bash
[[ "${*: -1}" != systemd-oomd || -f "$STATE/pkg-systemd-oomd" ]]
SH2
chmod +x "$TMP/bin/dpkg"
mv "$TMP/bin/systemctl" "$TMP/bin/systemctl-present"
cat > "$TMP/bin/systemctl" <<'SH2'
#!/bin/bash
if [[ "$*" == *systemd-oomd.service* && ! -f "$STATE/pkg-systemd-oomd" ]]; then
 echo "systemctl $*" >> "$CALLS"
 echo 'Unit systemd-oomd.service could not be found.' >&2
 [[ "$1" == is-active ]] && exit 4
 exit 5
fi
exec "$FIXTURE/bin/systemctl-present" "$@"
SH2
chmod +x "$TMP/bin/systemctl"
run_tools check
assert 'oomd missing package reported without apt mutation' 'grep -q "WARN.*systemd-oomd.*missing" "$TMP/out" && ! grep -q "apt-get .*install" "$CALLS"'
runv
assert 'verifier reports inactive oomd' 'grep -q "FAIL.*systemd-oomd inactive" "$TMP/out"'
run_tools install
assert 'oomd package installed before service activation' '[[ -f "$STATE/pkg-systemd-oomd" ]] && awk '\''/apt-get .*install.*systemd-oomd/{p=1} /systemctl .*systemd-oomd.service/ && p{ok=1} END{exit !ok}'\'' "$CALLS"'
runv
assert 'verifier reports active oomd after install' 'grep -q "PASS.*systemd-oomd active" "$TMP/out"'
run_tools install
assert 'installed oomd package is not requested again' '! grep -q "apt-get .*install.*systemd-oomd" "$CALLS"'
finish
