#!/bin/bash
# Preflight calibration: configs-aware defaults and memory storage, all on a
# fake machine. No package queries, downloads or real swap allocations.
source "$(dirname "${BASH_SOURCE[0]}")/memory-fixture.sh"
mkdir -p "$TMP/core-bin" "$ROOT/tmp"
# Control command availability too: the real host's tesseract must not make
# an enabled-but-missing OCR footprint disappear from this fixture.
for c in bash dirname basename mkdir date hostname sed awk grep cut tail head sort xargs cat readlink stat python3 rm touch chmod tee; do
  ln -s "/usr/bin/$c" "$TMP/core-bin/$c"
done
export PATH="$TMP/bin:$TMP/core-bin"
cat > "$TMP/bin/df" <<'SH'
#!/bin/bash
path="${*: -1}"; mp=/; free=$(cat "$STATE/root-free")
if [[ -e "$STATE/separate-home" && "$path" == "$HOME"* ]]; then
  mp=/home; free=$(cat "$STATE/home-free")
elif [[ "$path" == "$ROOT/tmp" ]]; then
  mp=/tmp; free=$(cat "$STATE/tmp-free")
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 999999999 0 %s 0%% %s\n' "$free" "$mp"
SH
chmod +x "$TMP/bin/df"
base() {
  conf headless=yes group_cli_system=no group_desktop=no group_apps=no group_editors=no \
    group_network=no group_dev_core=no group_dev_java=no group_dev_python=no \
    group_dev_cloud=no group_dev_flutter_deps=no lang_python=no lang_node=no lang_flutter=no \
    component_claude_skills=no disk_headroom_gb=0 space_check=enforce "$@"
  mem 8192
  : > "$STATE/swaps"; : > "$ROOT/etc/fstab"
  rm -f "$ROOT/swap.img" "$ROOT/swapfile" "$ROOT/swap.setup-kit" "$STATE/separate-home"
  echo 41943040 > "$STATE/root-free"; echo 41943040 > "$STATE/home-free"
  echo 1048576 > "$STATE/tmp-free"; echo tmpfs > "$STATE/fstype"
}
run00() { bash "$KIT_DIR/profiles/workstation/00-disk-space.sh" "${1:-check}" > "$TMP/out" 2>&1; rc=$?; }
unset_tools() { sed -i '/^component_dictation=/d; /^component_ocr=/d; /^component_tts=/d' "$HOST_CONF"; }

base; unset_tools; run00
assert 'configs=no: no dictation, OCR, TTS or private clone footprint' \
  '! grep -qE "(dictation:|ocr:|tts:|dotfiles:)" "$TMP/out"'
base component_dictation=yes component_ocr=yes component_tts=yes; run00
assert 'explicit component yes values still budget all three with configs=no' \
  'grep -q "dictation:" "$TMP/out" && grep -q "ocr:" "$TMP/out" && grep -q "tts:" "$TMP/out"'
base; unset_tools; sed -i '/^configs=/d' "$HOST_CONF"; run00
assert 'owner defaults retain all three components and the private clone' \
  'grep -q "dictation:" "$TMP/out" && grep -q "ocr:" "$TMP/out" && grep -q "tts:" "$TMP/out" && grep -q "dotfiles:" "$TMP/out"'
base; unset_tools; echo 2097152 > "$STATE/root-free"; run00 install
assert 'configs=no: a viable small install passes instead of exiting 3' '[[ "$rc" == 0 ]]'

base component_oom_zram=yes; run00
assert '8 GiB machine: budget a new RAM-sized disk overflow on root' \
  'grep -qE "swap overflow.*8.0G.*→ /$" "$TMP/out"'
base component_oom_zram=yes; mem 7681; run00
assert 'reserved RAM: overflow rounds up to the nominal 8 GiB' \
  'grep -qE "swap overflow.*8.0G" "$TMP/out"'
base component_oom_zram=yes
python3 -I -c 'import sys; open(sys.argv[1], "wb").truncate(4*1024**3)' "$ROOT/swap.img"
printf '%s file %s 0 -2\n' "$ROOT/swap.img" "$((4*1024**3-4096))" > "$STATE/swaps"
run00
assert 'existing 4 GiB overflow: budget only the extra allocation' \
  'grep -qE "swap overflow.*4.0G" "$TMP/out" && ! grep -qE "swap overflow.*8.0G" "$TMP/out"'
base component_oom_zram=yes
printf '/dev/fake-partition partition %s 0 -2\n' "$((3*1024**3))" > "$STATE/swaps"
run00
assert 'existing swap partition counts toward capacity; missing 5 GiB goes on root' \
  'grep -qE "swap overflow.*5.0G.*→ /$" "$TMP/out"'
base component_oom_zram=yes
printf '/dev/fake-partition partition %s 0 -2\n' "$((8*1024**3-4096))" > "$STATE/swaps"
run00
assert 'adequate existing swap including its header: no new disk charge' '! grep -q "swap overflow" "$TMP/out"'
base component_oom_zram=yes
python3 -I -c 'import sys; open(sys.argv[1], "wb").truncate(8*1024**3+4096)' "$ROOT/swap.img"
printf '%s file %s 0 -2\n' "$ROOT/swap.img" "$((4*1024**3-4096))" > "$STATE/swaps"
run00
assert 'already allocated swap tail: no additional allocation charged' '! grep -q "swap overflow" "$TMP/out"'
base component_oom_zram=yes; mem 15872; run00
assert 'nominal 16 GiB auto policy: no disk swap charged' '! grep -q "swap overflow" "$TMP/out"'
base component_oom_zram=yes swap_policy=zram+disk; mem 32768; run00
assert 'explicit disk policy above the small-box boundary: retain 4 GiB target' \
  'grep -qE "swap overflow.*4.0G" "$TMP/out"'
base component_oom_zram=yes swap_policy=zram-only; run00
assert 'explicit zram-only policy: no disk swap charged' '! grep -q "swap overflow" "$TMP/out"'
base; run00
assert 'disabled memory component: no disk swap charged' '! grep -q "swap overflow" "$TMP/out"'
base component_oom_zram=yes; echo 7864320 > "$STATE/root-free"; run00 install
assert 'overflow that cannot fit stops the calibration install with exit 3' \
  '[[ "$rc" == 3 ]] && grep -q "SHORT BY" "$TMP/out"'
base component_oom_zram=yes
touch "$STATE/separate-home"; echo 102400 > "$STATE/home-free"; run00 install
assert 'swap growth belongs to root, independent of a nearly full separate HOME' \
  '[[ "$rc" == 0 ]] && grep -qE "swap overflow.*→ /$" "$TMP/out"'

base tmp_on_disk=yes; echo 2097152 > "$STATE/root-free"; run00 install
assert 'live tmpfs: disk scratch is charged to the future backing root and can stop an install' \
  '[[ "$rc" == 3 ]] && grep -qE "tmp: disk scratch.*2.0G.*→ /$" "$TMP/out"'
base tmp_on_disk=yes
echo '/dev/fake-tmp /tmp ext4 defaults 0 2' > "$ROOT/etc/fstab"; echo ext4 > "$STATE/fstype"
run00 install
assert 'existing separate disk /tmp: scratch is charged to that filesystem' \
  '[[ "$rc" == 3 ]] && grep -qE "tmp: disk scratch.*→ /tmp$" "$TMP/out"'
base tmp_on_disk=yes
echo 'tmpfs /tmp tmpfs defaults 0 0' > "$ROOT/etc/fstab"; run00
assert 'explicit fstab tmpfs is preserved: no disk scratch charge' '! grep -q "tmp: disk scratch" "$TMP/out"'
base; run00
assert 'tmp_on_disk=no: no scratch charge' '! grep -q "tmp: disk scratch" "$TMP/out"'
base; sed -i '/^component_oom_zram=/d; /^tmp_on_disk=/d' "$HOST_CONF"; run00
assert 'default memory policy budgets both disk overflow and disk scratch' \
  'grep -q "swap overflow" "$TMP/out" && grep -q "tmp: disk scratch" "$TMP/out"'

finish
