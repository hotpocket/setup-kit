#!/bin/bash
# System policy covers user clones and bare repos alike. Keep unrelated keys.
section "git fsync ($MODE)"
git_fsync_changed=0; git_fsync_failed=0
for git_fsync_pair in core.fsync=committed core.fsyncMethod=fsync; do
  git_fsync_key="${git_fsync_pair%%=*}"; git_fsync_want="${git_fsync_pair#*=}"
  if [[ "$(git config --system --includes --get "$git_fsync_key" 2>/dev/null)" == "$git_fsync_want" ]]; then
    continue
  fi
  git_fsync_changed=1
  warn "git fsync: system $git_fsync_key missing or different; want $git_fsync_want"
  if do_or_say sudo git config --system --replace-all "$git_fsync_key" "$git_fsync_want" \
      && { (( ! INSTALL )) || [[ "$(git config --system --includes --get "$git_fsync_key" 2>/dev/null)" == "$git_fsync_want" ]]; }; then
    :
  else
    fail "git fsync: cannot set system $git_fsync_key; rerun install with working sudo"
    miss "git fsync: system $git_fsync_key not reconciled (components/git-fsync.md)"
    git_fsync_failed=1
  fi
done
if (( git_fsync_failed )); then
  return 1
elif (( ! git_fsync_changed )); then
  ok "git fsync: system settings already correct; nothing to change"
elif (( INSTALL )); then
  ok "git fsync: system settings reconciled"
fi
