#!/bin/bash
# With legacy stacks disabled and new keys unset, no phase may activate new
# tools. Expected behavior is fixed here, independent of HEAD/history depth.
# A positive control proves the call log can observe an activated component.
source "$(dirname "$0")/tools-fixture.sh"
conf_tools configs=no lang_python=no lang_node=no lang_flutter=no component_claude_skills=no component_claude_code=no space_check=no
for phase in 00-disk-space 04-languages 07-components 08-claude-skills; do
  rm -rf "$HOME"; mkdir -p "$HOME"
  : > "$CALLS"
  bash "$KIT_DIR/profiles/workstation/$phase.sh" install > "$TMP/out" 2>&1
  assert "unset tool flags add no calls in $phase" '[[ ! -s "$CALLS" ]]'
done
conf_tools configs=no lang_python=no lang_node=no lang_flutter=no component_claude_skills=no component_claude_code=no component_uv=yes
run_tools install
assert 'default-path call log can observe an activated tool' 'grep -q "^curl .*uv-" "$CALLS" && [[ -x "$HOME/.local/bin/uv" ]]'
finish
