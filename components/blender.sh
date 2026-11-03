#!/bin/bash
source "$KIT_DIR/components/tool-common.sh"
section "blender ($MODE) — components/blender.md"
BLENDER_DIR="$HOME/.local/opt/blender-$BLENDER_VERSION-linux-x64"
blender_install() (
  tool_x64 blender || exit 1
  mkdir -p "$HOME/.local/opt" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$HOME/.local/opt" blender "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "https://mirror.blender.org/release/Blender${BLENDER_VERSION%.*}/blender-$BLENDER_VERSION-linux-x64.tar.xz" "$BLENDER_SHA256" "$stage/blender.tar.xz" \
    && tar -xJf "$stage/blender.tar.xz" -C "$stage" \
    && [[ -x "$stage/blender-$BLENDER_VERSION-linux-x64/blender" ]] || exit 1
  if [[ -e "$BLENDER_DIR" ]]; then
    echo "refusing to replace drifted $BLENDER_DIR; move it aside after inspection" >&2; exit 1
  fi
  mv "$stage/blender-$BLENDER_VERSION-linux-x64" "$BLENDER_DIR"
)
if [[ -x "$BLENDER_DIR/blender" && "$("$BLENDER_DIR/blender" --version 2>/dev/null | head -1)" == "Blender $BLENDER_VERSION LTS" ]]; then
  ok "blender $BLENDER_VERSION"
else
  warn "blender $BLENDER_VERSION missing or drifted"
  do_or_say blender_install || miss "blender: pinned archive installation failed"
fi
for pair in opt bin; do
  if [[ "$pair" == opt ]]; then target="blender-$BLENDER_VERSION-linux-x64"; link="$HOME/.local/opt/blender"
  else target=../opt/blender/blender; link="$HOME/.local/bin/blender"; fi
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then ok "blender $pair link"
  else
    warn "blender $pair link missing or drifted"
    (( ! INSTALL )) || [[ -x "$BLENDER_DIR/blender" ]] || continue
    do_or_say tool_link "$target" "$link" || miss "blender: cannot link $link"
  fi
done
