#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
cat > "$TMP/bin/dpkg" <<'SH2'
#!/bin/bash
[[ -f "$STATE/pkg-${*: -1}" ]]
SH2
chmod +x "$TMP/bin/dpkg"
for package in openjdk-21-jdk-headless systemd-oomd systemd-zram-generator; do
  rm -f "$STATE/pkg-$package"
  printf '%s\n' "$package" > "$STATE/apt-removal-for"
  conf_tools component_flutter_headless=yes component_oom_zram=yes
  run_tools install
  assert "$package conflict is simulated and never applied" 'grep -q "^apt-get .*install -s.*$package" "$CALLS" && ! grep "^apt-get .*install" "$CALLS" | grep -v -- " -s " | grep -q "$package" && grep -q "would remove.*protected-package" "$TMP/out"'
done
rm "$STATE/apt-removal-for"
rm -f "$STATE/pkg-openjdk-21-jdk-headless"
touch "$STATE/apt-sim-fail"; run_tools install
assert 'failed resolver simulation refuses component install' 'grep -q "dry-run failed" "$TMP/out" && ! grep "^apt-get .*install" "$CALLS" | grep -v -- " -s " | grep -q "openjdk-21-jdk-headless"'
rm "$STATE/apt-sim-fail"; run_tools install
assert 'safe resolver transaction keeps the mechanical no-remove guard' 'grep "^apt-get .*install" "$CALLS" | grep -v -- " -s " | grep -q -- "--no-remove.*openjdk-21-jdk-headless"'
rm -f "$STATE/pkg-openjdk-21-jdk-headless"; run_tools check
assert 'doctor performs no privileged resolver simulation' '! grep -q "^sudo .*apt-get" "$CALLS"'
finish
