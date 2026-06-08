#!/bin/bash
# Apps with no apt repo — installed from vendor .debs (manifests/debs.list).
# Fields: name<TAB>method<TAB>arg
#   url    — stable latest-version link, fetch + install
#   github — owner/repo:asset-suffix, resolve latest release asset
#   manual — vendor only ships version-pinned URLs; doctor-warn + log
SCRIPT_NAME="ws-02b-debs"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "direct-deb apps ($MODE)"

install_deb() {  # install_deb <name> <url>
  local name="$1" url="$2" tmp
  tmp="$(mktemp -d)"
  log "downloading $name: $url"
  if curl -fsSL -o "$tmp/$name.deb" "$url" \
     && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$name.deb" \
        >>"$LOG_DIR/$SCRIPT_NAME.log" 2>&1; then
    log "installed: $name"
  else
    miss "deb: $name ($url)"
  fi
  rm -rf "$tmp"
}

while IFS=$'\t' read -r name method arg grp; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ -n "$grp" ]] && ! group_on "$grp"; then
    ok "$name: gated off (group_$grp)"
    continue
  fi
  if pkg_installed "$name"; then
    ok "$name"
    continue
  fi
  case "$method" in
    url)
      warn "$name missing"
      if (( INSTALL )); then install_deb "$name" "$arg"; else hint "$arg"; fi
      ;;
    github)
      warn "$name missing"
      repo="${arg%%:*}" suffix="${arg##*:}"
      if (( INSTALL )); then
        url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
              | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep "$suffix\$" | head -1)
        if [[ -n "$url" ]]; then install_deb "$name" "$url"
        else miss "deb: $name (no $suffix asset in latest $repo release)"; fi
      else
        hint "latest $suffix from github.com/$repo releases"
      fi
      ;;
    manual)
      # not kit-actionable (vendor ships only version-pinned URLs) — keep
      # informational so a fully-converged run still reads CONVERGED
      ok "$name: not installed (manual vendor deb — by design)"
      hint "$arg"
      ;;
    *) warn "$name: unknown method '$method' in debs.list" ;;
  esac
done < <(grep -v '^\s*#' "$MANIFEST_DIR/debs.list" 2>/dev/null)
