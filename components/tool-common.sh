#!/bin/bash
# Sourced only by opted-in tool components. Final files appear by rename.
source "$KIT_DIR/manifests/tool-versions.conf"
# shellcheck disable=SC2034 # consumed by flutter-headless.sh
TOOL_ROOT="${KIT_TOOL_ROOT:-}"
tool_version_is() { # executable tool-name version; vendor target metadata may follow
  local name version _metadata
  [[ -x "$1" ]] || return 1
  read -r name version _metadata < <("$1" --version 2>/dev/null)
  [[ "$name" == "$2" && "$version" == "$3" ]]
}
tool_property() { # Java .properties assignment; spaces around '=' are optional
  awk -v key="$2" 'index($0,"=") {
    k=substr($0,1,index($0,"=")-1); gsub(/^[ \t]+|[ \t\r]+$/,"",k)
    if(k==key) {v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t\r]+$/,"",v); print v; exit}
  }' "$1" 2>/dev/null
}
tool_x64() { [[ "$(uname -m)" == x86_64 ]] || { miss "$1: only Linux x86_64 is pinned"; return 1; }; }
# Staging names carry their owner's PID. Recover only dead owners; a live
# concurrent provisioner keeps its scratch. Final artifacts are never swept.
tool_stage() { # parent label owner-pid
  local parent="$1" label="$2" owner="$3" old pid tail
  for old in "$parent/.$label."*; do
    [[ -d "$old" && ! -L "$old" ]] || continue
    tail=${old##*/.$label.}; pid=${tail%%.*}
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null && [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" != Z* ]]; then
      continue
    fi
    rm -rf -- "$old"
  done
  mktemp -d "$parent/.$label.$owner.XXXXXX"
}
tool_fetch() { # URL SHA256 destination — caller owns scratch directory
  local url="$1" sha="$2" dest="$3"
  curl -fsSL --retry 3 "$url" -o "$dest.part" \
    && printf '%s  %s\n' "$sha" "$dest.part" | sha256sum -c - \
    && mv "$dest.part" "$dest"
}
tool_link() { # target link — caller runs inside do_or_say
  local target="$1" link="$2" tmp
  [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0
  [[ ! -e "$link" || -L "$link" ]] || { echo "refusing unmanaged $link" >&2; return 1; }
  mkdir -p "$(dirname "$link")" || return 1
  tmp=$(mktemp -d "$(dirname "$link")/.link.XXXXXX") || return 1
  ln -s "$target" "$tmp/link" && mv -Tf "$tmp/link" "$link"
  local rc=$?; rmdir "$tmp"; return "$rc"
}
tool_write() { # content path; user-owned, preserve external symlinks
  local want="$1" path="$2" tmp perm=644
  [[ -f "$path" && "$(cat "$path")" == "$want" ]] && return 0
  [[ ! -L "$path" ]] || { miss "headless environment: refusing symlink $path; update its owner"; return 1; }
  mkdir -p "$(dirname "$path")" || return 1
  [[ ! -f "$path" ]] || perm=$(stat -c %a "$path")
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  printf '%s\n' "$want" > "$tmp" && chmod "$perm" "$tmp" && mv -f "$tmp" "$path"
}
