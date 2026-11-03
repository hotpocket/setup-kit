#!/bin/bash
source "$KIT_DIR/components/tool-common.sh"
section "uv ($MODE) — components/uv.md"
uv_install() (
  tool_x64 uv || exit 1
  mkdir -p "$HOME/.local/bin" || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$HOME/.local/bin" uv "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  tool_fetch "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" "$UV_SHA256" "$stage/uv.tar.gz" \
    && tar -xzf "$stage/uv.tar.gz" -C "$stage" \
    && [[ -x "$stage/uv-x86_64-unknown-linux-gnu/uv" && -x "$stage/uv-x86_64-unknown-linux-gnu/uvx" ]] \
    && mv -f "$stage/uv-x86_64-unknown-linux-gnu/uv" "$HOME/.local/bin/uv" \
    && mv -f "$stage/uv-x86_64-unknown-linux-gnu/uvx" "$HOME/.local/bin/uvx"
)
if [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" \
      && "$("$HOME/.local/bin/uv" --version 2>/dev/null)" == "uv $UV_VERSION" \
      && "$("$HOME/.local/bin/uvx" --version 2>/dev/null)" == "uvx $UV_VERSION" ]]; then
  ok "uv/uvx $UV_VERSION"
else
  warn "uv/uvx $UV_VERSION missing or drifted"
  do_or_say uv_install || miss "uv: pinned archive installation failed"
fi
