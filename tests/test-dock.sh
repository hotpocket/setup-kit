#!/bin/bash
# Calibration for the dock phase (06y-dock.sh + manifests/dock.list): the dock
# is DECLARED — favorites become exactly the manifest's installed entries, in
# manifest order. Ubuntu's defaults (firefox, thunderbird, app store, help)
# fall off; entries whose app isn't installed are skipped, not pinned blind;
# @group-gated rows follow the host conf. Stub gsettings records the write.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/apps" "$TMP/bin" "$TMP/home"
for d in google-chrome org.gnome.Terminal firefox_firefox thunderbird_thunderbird gimp magic; do : > "$TMP/apps/$d.desktop"; done
cat > "$TMP/dock.list" <<'LIST'
# order = dock order
google-chrome.desktop
org.gnome.Terminal.desktop
com.obsproject.Studio.desktop   @media    # not installed in this test
gimp.desktop                    @media
magic.desktop
md.obsidian.Obsidian.desktop              # not installed in this test
LIST
cat > "$TMP/bin/gsettings" <<EOF2
#!/bin/bash
if [[ "\$1" == get ]]; then echo "['firefox_firefox.desktop', 'thunderbird_thunderbird.desktop', 'google-chrome.desktop']"; exit 0; fi
[[ "\$1" == set ]] && { echo "\$4" > "$TMP/set"; exit 0; }
exit 1
EOF2
chmod +x "$TMP/bin/gsettings"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { rm -f "$TMP/set"; HOME="$TMP/home" HOST_CONF="$TMP/host.conf" DBUS_SESSION_BUS_ADDRESS=stub DOCK_LIST="$TMP/dock.list" \
        DOCK_APP_DIRS="$TMP/apps" PATH="$TMP/bin:$PATH" bash "$KIT_DIR/profiles/workstation/06y-dock.sh" "$1" 2>&1; }
echo "dock manifest"
printf 'group_desktop=yes\ngroup_media=yes\n' > "$TMP/host.conf"
out="$(run install)"
assert "sets favorites to exactly the installed manifest entries, in order" \
  '[[ "$(cat "$TMP/set" 2>/dev/null)" == "['"'"'google-chrome.desktop'"'"', '"'"'org.gnome.Terminal.desktop'"'"', '"'"'gimp.desktop'"'"', '"'"'magic.desktop'"'"']" ]]'
assert "firefox/thunderbird are gone"                   '! grep -q "firefox\|thunderbird" "$TMP/set"'
assert "an uninstalled entry is reported, not pinned"   'grep -q "com.obsproject.Studio.desktop.*not installed" <<<"$out"'
printf 'group_desktop=yes\ngroup_media=no\n' > "$TMP/host.conf"
out="$(run install)"
assert "@media rows drop out when the group is off"     '! grep -q gimp "$TMP/set"'
out="$(run check)"
assert "check mode changes nothing"                     '[[ ! -e "$TMP/set" ]] && grep -q "would" <<<"$out"'
printf 'group_desktop=no\n' > "$TMP/host.conf"
out="$(run install)"
assert "not a desktop install → phase is a no-op"       '[[ ! -e "$TMP/set" ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
