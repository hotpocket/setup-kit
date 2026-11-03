#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
# The workstation has gcloud. Model a clone where command lookup cannot find it.
command() {
 if [[ "${1:-}" == -v && "${2:-}" == gcloud ]]; then return 1; fi
 builtin command "$@"
}
export -f command
conf group_dev_cloud=yes skip_pkgs=google-cloud-cli
runv
assert 'gcloud skipped by package policy is not required' '! grep -q "FAIL.*gcloud missing" "$TMP/out"'
conf group_dev_cloud=yes 'skip_pkgs="google-cloud-cli other-package"'
runv
assert 'gcloud skip policy accepts quoted package lists' '! grep -q "FAIL.*gcloud missing" "$TMP/out"'
conf group_dev_cloud=yes skip_pkgs=google-cloud-cli-extra
runv
assert 'gcloud skip requires the exact package token' 'grep -q "FAIL.*gcloud missing" "$TMP/out"'
conf group_dev_cloud=yes
runv
assert 'gcloud absence fails when requested' 'grep -q "FAIL.*gcloud missing" "$TMP/out"'
finish
