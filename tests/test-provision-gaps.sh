#!/bin/bash
# Three things the kit warned about but never provisioned (2026-09-05):
#   bun (gstack's browse daemon), Android cmdline-tools (sdkmanager), and
#   ydotool on Wayland (dictation could listen but not type). Each phase, in
#   check mode against an empty HOME, must now say what it WOULD do — a phase
#   that only warns is the defect this test exists to catch.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
printf 'component_dictation=yes\ncomponent_claude_skills=yes\nlang_flutter=yes\n' > "$TMP/host.conf"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { HOME="$TMP/home" HOST_CONF="$TMP/host.conf" XDG_SESSION_TYPE="${SESSION:-wayland}" \
        PATH="$TMP/bin:$(tr : "\n" <<<"$PATH" | grep -vE "/\.local/bin|/\.bun/" | paste -sd:)" bash "$KIT_DIR/profiles/workstation/$1" check 2>&1; }
# bun/ydotool/sdkmanager must look absent regardless of this box
mkdir -p "$TMP/bin"; for b in bun ydotool wtype; do printf '#!/bin/sh\nexit 127\n' > "$TMP/bin/$b"; done
# ... a stub that exits 127 still "exists" to command -v; hide instead
rm -f "$TMP/bin/"*
echo "provisioning gaps"
out="$(run 08-claude-skills.sh)"
assert "bun: phase 08 offers to install it"            'grep -qE "\[would\].*bun" <<<"$out"'
assert "claude code: native installer, one command"    'grep -qE "\[would\].*claude.ai/install.sh \| bash" <<<"$out"'
assert "claude code: never via npm"                    '! grep -rq "anthropic-ai/claude-code" "$KIT_DIR/manifests" "$KIT_DIR/profiles"'
out="$(run 05-flutter-android.sh)"
assert "cmdline-tools: phase 05 offers to install them" 'grep -qiE "\[would\].*cmdline-tools|would.*sdkmanager|cmdline-tools.*install" <<<"$out"'
assert "cmdline-tools: no longer a manual hint"         '! grep -q "unzip cmdline-tools into" <<<"$out"'
out="$(run 07-components.sh)"
assert "ydotool: phase 07 offers to install it on Wayland" 'grep -qE "\[would\].*ydotool" <<<"$out"'
assert "ydotool: input group + user service are part of it" 'grep -qE "input group|ydotool.service|ydotoold" <<<"$out"'
out="$(SESSION=x11 run 07-components.sh)"
assert "ydotool: not pushed onto an X11 session"        '! grep -q "ydotool" <<<"$out"'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
