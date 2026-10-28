#!/bin/bash
# Calibration for component_claude_brevity (08-claude-skills). A
# UserPromptSubmit hook that injects the brevity rule into every Claude Code
# prompt, for a box without the owner's .configs (whose settings.json carries
# its own). The hook cats ~/.local/share/setup-kit/claude-brevity.md, a link to
# the kit's components/claude-brevity.md.
#
# Contract (fake HOME, no network):
#   A. unset: off, nothing written
#   B. yes, no settings.json: check writes nothing; install writes the hook,
#      links the text, and the hook's command prints the brevity rule
#   C. yes, settings.json with other keys and another UserPromptSubmit hook:
#      both kept, brevity added once, a second install adds nothing
#   D. yes, settings.json a symlink (managed elsewhere) without it: warns, untouched
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
H="$TMP/home"; S="$H/.claude/settings.json"; LINK="$H/.local/share/setup-kit/claude-brevity.md"
conf() { printf '%s\n' component_claude_code=no component_claude_skills=no "$@" > "$TMP/host.conf"; }
run08() { PATH="/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
reset() { rm -rf "$H"; mkdir -p "$H"; }
# the commands of every UserPromptSubmit hook, one per line
hooks() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for g in d.get("hooks",{}).get("UserPromptSubmit",[]):
  for h in g.get("hooks",[]): print(h["command"])' "$S"; }
merged_hook() { python3 -I - "$S" "$TMP/before.json" <<'PY'
import json, sys
data, old = [json.load(open(path)) for path in sys.argv[1:]]
command = 'cat "$HOME/.local/share/setup-kit/claude-brevity.md"'
groups = data["hooks"]["UserPromptSubmit"]
assert sum(h.get("type") == "command" and h.get("command") == command
           for group in groups for h in group["hooks"]) == 1
assert groups.pop() == {"hooks": [{"type": "command", "command": command}]}
if not groups:
    data["hooks"].pop("UserPromptSubmit")
if not data["hooks"]:
    data.pop("hooks")
assert data == old
PY
}

reset; conf; MODE=install run08
assert "A. unset: off, nothing written" '[[ ! -e "$S" && ! -e "$LINK" ]]'

reset; conf component_claude_brevity=yes; run08
assert "B1. check: warns, writes nothing" 'grep -q "WARN.*brevity" "$TMP/out" && [[ ! -e "$S" && ! -e "$LINK" ]]'
MODE=install run08
assert "B2. install: hook written, text linked, the hook prints the rule" \
  '[[ "$(readlink -f "$LINK")" == "$KIT_DIR/components/claude-brevity.md" ]] && [[ "$(hooks | wc -l)" == 1 ]] \
   && HOME="$H" bash -c "$(hooks)" | grep -q "Be as brief as possible"'

reset; mkdir -p "$H/.claude"
printf '{"theme":"dark","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo other"}]}],"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}\n' > "$S"
conf component_claude_brevity=yes; MODE=install run08; MODE=install run08
assert "C. existing settings kept, brevity added once after two installs" \
  'hooks | grep -qx "echo other" && [[ "$(hooks | grep -c claude-brevity)" == 1 ]] \
   && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"theme\"]==\"dark\" and d[\"hooks\"][\"Stop\"]" "$S"'

reset; mkdir -p "$H/.claude"; printf '{"theme":"dark"}\n' > "$TMP/managed.json"; ln -s "$TMP/managed.json" "$S"
conf component_claude_brevity=yes; MODE=install run08
assert "D. symlinked settings.json without it: warns managed elsewhere, untouched" \
  'grep -q "WARN.*settings.json.*managed elsewhere" "$TMP/out" && [[ "$(cat "$TMP/managed.json")" == "{\"theme\":\"dark\"}" ]]'

# A filename mention is not a UserPromptSubmit command hook. Each fixture
# retains a sentinel so a successful merge must also preserve existing keys.
for mention in permission other-event echo wrong-file prompt-type; do
  reset; mkdir -p "$H/.claude"
  python3 -I - "$S" "$mention" <<'PY'
import json, sys
path, case = sys.argv[1:]
command = 'cat "$HOME/.local/share/setup-kit/claude-brevity.md"'
data = {"theme": "dark"}
if case == "permission":
    data["permissions"] = {"allow": ["Read(claude-brevity.md)"]}
elif case == "other-event":
    data["hooks"] = {"Stop": [{"hooks": [{"type": "command", "command": command}]}]}
else:
    hook = {
        "echo": {"type": "command", "command": "echo claude-brevity"},
        "wrong-file": {"type": "command", "command": "cat /elsewhere/claude-brevity.md"},
        "prompt-type": {"type": "prompt", "prompt": "Read claude-brevity.md"},
    }[case]
    data["hooks"] = {"UserPromptSubmit": [{"hooks": [hook]}]}
with open(path, "w") as f:
    json.dump(data, f)
PY
  cp "$S" "$TMP/before.json"
  conf component_claude_brevity=yes; run08
  assert "E. $mention mention: check reports the missing hook and writes nothing" \
    'grep -q "WARN.*settings.json has no brevity hook" "$TMP/out" && ! grep -q "OK.*settings.json has the brevity hook" "$TMP/out" && cmp -s "$S" "$TMP/before.json"'
  MODE=install run08
  assert "E. $mention mention: install adds the actual prompt command and keeps other settings" \
    'merged_hook'
done

reset; mkdir -p "$H/.claude"
printf '{"permissions":{"allow":["Read(claude-brevity.md)"]}}\n' > "$TMP/managed.json"
cp "$TMP/managed.json" "$TMP/before.json"; ln -s "$TMP/managed.json" "$S"
conf component_claude_brevity=yes; MODE=install run08
assert "F. symlinked settings with a permission mention: warns, never writes through" \
  'grep -q "WARN.*settings.json.*managed elsewhere" "$TMP/out" && [[ -L "$S" ]] && cmp -s "$TMP/managed.json" "$TMP/before.json"'

echo "test-claude-brevity: $pass passed, $fail failed"
(( fail == 0 ))
