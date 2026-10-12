#!/usr/bin/env bash
# Live-test cleanup only: the creation response owns the one eligible workspace.
# Caller loads its backend and binds an isolated home before sourcing libraries.
# Keep project records: project deletion may archive workspaces we did not create.
fm_test_paseo_archive_created() { # <physical-test-root> <creation-response>
  local root=$1 receipt=$2 id list cwd physical
  [ -f "$receipt" ] || return 0
  id=$(jq -er '.workspaceId | strings | select(length > 0)' "$receipt") || return 1
  list=$(fm_backend_paseo_cli workspace ls --json) || return 1
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null || return 1
  # Already absent is idempotent; duplicates or malformed rows fail closed.
  [ "$(printf '%s' "$list" | jq --arg id "$id" '[.[] | select(.workspaceId == $id)] | length')" != 0 ] || return 0
  cwd=$(printf '%s' "$list" | jq -er --arg id "$id" \
    '[.[] | select(.workspaceId == $id)] | select(length == 1) | .[0].cwd | strings | select(length > 0)') || return 1
  physical=$(cd "$cwd" && pwd -P) || return 1
  case "$physical/" in "$root/"*) ;; *) echo 'cleanup: created workspace cwd escaped test root; retained' >&2; return 1 ;; esac
  fm_backend_paseo_cli workspace archive "$id"
}

fm_test_paseo_cleanup_live() { # <physical-test-root> <creation-response> <target> <label>
  [ "${FM_TEST_PASEO_CLEANED:-0}" = 0 ] || return 0
  FM_TEST_PASEO_CLEANED=1
  [ -z "$3" ] || fm_backend_paseo_rollback_created "$3" "$4" || {
    echo 'cleanup: could not close test terminal; workspace retained' >&2
    return 1
  }
  fm_test_paseo_archive_created "$1" "$2"
}
