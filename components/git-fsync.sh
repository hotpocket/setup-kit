#!/bin/bash
# System policy covers user clones and bare repos alike. Keep unrelated keys.
section "git fsync ($MODE)"
git_fsync_changed=0; git_fsync_failed=0
# Required bits: loose objects, packs, references. Git adds positive components
# after removing negative components from its platform default (pack here).
# Git 2.53: environment.c parse_fsync_components, write-or-die.h definitions.
git_fsync_covers_committed() {
  local rest="$1" token bits positive=0 negative=0 base=2 negate
  while [[ -n "$rest" ]]; do
    rest="${rest#"${rest%%[!$' ,\t\n\r']*}"}"
    [[ -n "$rest" ]] || break
    if [[ "$rest" == none ]]; then base=0; break; fi
    token="${rest%%,*}"
    if [[ "$rest" == *,* ]]; then rest="${rest#*,}"; else rest=; fi
    negate=0; [[ "$token" != -* ]] || { negate=1; token="${token#-}"; }
    case "$token" in
      loose-object) bits=1 ;; pack) bits=2 ;; reference) bits=4 ;;
      objects) bits=3 ;; committed|added|all) bits=7 ;;
      pack-metadata|commit-graph|index|derived-metadata|none) bits=0 ;;
      *) return 1 ;;
    esac
    if (( negate )); then negative=$((negative | bits)); else positive=$((positive | bits)); fi
  done
  (( ((base & ~negative) | positive) == 7 ))
}

# /dev/null prevents the caller's incidental checkout from adding local config.
# NUL-separated origins preserve spaces and avoid Git's filename quoting.
git_fsync_writer_query() {
  local repo="$1" key="$2" scope="$3"
  local -a query=(git --git-dir="$repo" config --null --includes --show-origin)
  [[ "$scope" != system ]] || query+=(--system)
  query+=(--get "$key")
  [[ "$git_fsync_uid" =~ ^[0-9]+$ && "$git_fsync_home" == /* ]] || return 77
  local -a probe=(env -i "HOME=$git_fsync_home" "XDG_CONFIG_HOME=$git_fsync_home/.config" "PATH=$PATH" /bin/sh -c '
    expected=$1; shift
    [ "$(id -u)" = "$expected" ] || exit 77
    for directory in "$HOME" "$HOME/.config" "$HOME/.config/git"; do
      if [ "$directory" = "$HOME" ] || [ -e "$directory" ]; then
        [ -d "$directory" ] && [ -r "$directory" ] && [ -x "$directory" ] || exit 77
      fi
    done
    for config in "$HOME/.gitconfig" "$HOME/.config/git/config"; do
      [ ! -e "$config" ] || [ -r "$config" ] || exit 77
    done
    exec "$@"
  ' kit-fsync "$git_fsync_uid" "${query[@]}")
  if [[ "$git_fsync_uid" != "$(id -u)" ]]; then
    probe=(sudo -n -H -u "$git_fsync_writer" -- "${probe[@]}")
  fi
  "${probe[@]}" 2>/dev/null
}
git_fsync_effective() {
  local label="$1" repo="$2" scope="${3:-}" key value origin good display="$1"
  [[ "$scope" != system ]] || display+=" system"
  local -a record
  for key in core.fsync core.fsyncMethod; do
    mapfile -d '' -t record < <(
      if [[ -n "$scope" ]]; then git_fsync_writer_query "$repo" "$key" "$scope"
      else git --git-dir="$repo" config --null --includes --show-origin --get "$key" 2>/dev/null; fi
      printf '%s\0' "$?"
    )
    if [[ -n "$scope" ]] && { (( ${#record[@]} != 3 )) || [[ "${record[2]:-}" != 0 ]]; }; then
      fail "not checked: $label for writer $git_fsync_writer in $repo. Check noninteractive probe permissions and that the writer HOME and HOME/.config are readable, then rerun."
      git_fsync_failed=1
      return 1
    fi
    origin="${record[0]:-unavailable}"; value="${record[1]:-}"; good=0
    if (( ${#record[@]} != 3 )); then origin=unavailable; value=; fi
    if (( ${#record[@]} == 3 )) && [[ "${record[2]}" == 0 ]]; then
      if [[ "$key" == core.fsync ]]; then git_fsync_covers_committed "$value" && good=1
      elif [[ "$value" == fsync ]]; then good=1; fi
    fi
    if (( good )); then
      ok "git fsync: $display $key=$value from $origin"
    else
      fail "git fsync: $display $key lacks required durability from $origin; set $key=$([[ "$key" == core.fsync ]] && echo committed || echo fsync) there"
      git_fsync_failed=1
    fi
  done
  return 0
}

git_fsync_system_file="$(git var GIT_CONFIG_SYSTEM 2>/dev/null)"
git_fsync_system_file="${git_fsync_system_file:-${GIT_CONFIG_SYSTEM:-/etc/gitconfig}}"
for git_fsync_pair in core.fsync=committed core.fsyncMethod=fsync; do
  git_fsync_key="${git_fsync_pair%%=*}"; git_fsync_want="${git_fsync_pair#*=}"
  mapfile -d '' -t git_fsync_record < <(git --git-dir=/dev/null config --system --null --includes --show-origin --get "$git_fsync_key" 2>/dev/null)
  if [[ "${git_fsync_record[1]:-}" == "$git_fsync_want" ]]; then
    continue
  fi
  git_fsync_changed=1
  git_fsync_origin="${git_fsync_record[0]:-}"
  if [[ "$git_fsync_origin" == file:* && "$git_fsync_origin" != "file:$git_fsync_system_file" \
      && ! "${git_fsync_origin#file:}" -ef "$git_fsync_system_file" ]]; then
    fail "git fsync: system $git_fsync_key from include ${git_fsync_origin#file:}; set $git_fsync_key=$git_fsync_want there"
    git_fsync_failed=1
    continue
  fi
  warn "git fsync: system $git_fsync_key missing or different; want $git_fsync_want"
  if do_or_say sudo git config --system --replace-all "$git_fsync_key" "$git_fsync_want" \
      && { (( ! INSTALL )) || [[ "$(git --git-dir=/dev/null config --system --includes --get "$git_fsync_key" 2>/dev/null)" == "$git_fsync_want" ]]; }; then
    :
  else
    fail "git fsync: cannot set system $git_fsync_key; rerun install with working sudo"
    miss "git fsync: system $git_fsync_key not reconciled (components/git-fsync.md)"
    git_fsync_failed=1
  fi
done

git_fsync_effective 'invoking user' /dev/null
if [[ "$(conf_get component_git_hub no)" == yes ]]; then
  git_fsync_root="$(conf_get git_hub_root /srv/git)"
  git_fsync_writer="$(conf_get git_hub_user git)"
  git_fsync_passwd="$(getent passwd "$git_fsync_writer")"
  IFS=: read -r _ _ git_fsync_uid _ _ git_fsync_home _ <<< "$git_fsync_passwd"
  for git_fsync_entry in $(conf_get git_hub_repos ''); do
    git_fsync_slug="${git_fsync_entry%%:*}"; git_fsync_name="${git_fsync_slug##*/}"
    git_fsync_repo="$git_fsync_root/$git_fsync_name.git"
    if [[ -f "$git_fsync_repo/HEAD" ]]; then
      if git_fsync_effective "hub $git_fsync_name.git" "$git_fsync_repo" system; then
        git_fsync_effective "hub $git_fsync_name.git" "$git_fsync_repo" effective || true
      fi
    else
      warn "git fsync: hub $git_fsync_name.git not initialized; effective settings not checked"
    fi
  done
fi
ok "git fsync: other repositories local overrides are outside this check"

if (( git_fsync_failed )); then
  return 1
elif (( ! git_fsync_changed )); then
  ok "git fsync: system settings already correct; nothing to change"
elif (( INSTALL )); then
  ok "git fsync: system settings reconciled"
fi
