#!/usr/bin/env bash
# Bounded Treehouse recovery through fm-teardown.sh's --return-copy owner.
# Usage: fm-treehouse-recover.sh task <id> | pool <project-dir>
# Only this home's recorded ordinary Paseo reports are candidates. `pool`
# reads Treehouse's actual pool paths and returns success only if a matching
# slot was released, authorizing one allocation retry. `task` is the existing
# inactive-reconciliation hook. Neither path changes backlog or task outcomes.
# Unavailable inventories are not death; retained-work diagnostics go to stderr.
# Returns are bounded at 40s; teardown journals only within its first 20s, so
# the bound leaves the native return and receipt the rest. Pool intake starts
# at most 32 record reads before its 30s deadline (spawn bounds the whole
# attempt at 80s, room for one return started just before that deadline).
# Locks, positive generation claims, work safety, process and pipeline proofs,
# return journal and idempotence all belong to fm-teardown.sh.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

recover_task() { # <id> [pool-path-list]
  local id=$1 pools=${2:-} meta wt project out endpoint_state
  fm_task_id_path_safe "$id" || return 1
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || return 1
  [ "$(fm_meta_get "$meta" backend)" = paseo ] || return 1
  [ -z "$(fm_meta_get "$meta" worktree_state)" ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  wt=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  fm_treehouse_pool_slot "$project" "$wt" || return 1
  wt=$(CDPATH='' cd -- "$wt" && pwd -P) || return 1
  if [ -n "$pools" ]; then
    printf '%s\n' "$pools" | grep -Fx -- "$wt" >/dev/null || return 1
  fi
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  fm_backend_source paseo || return 1
  endpoint_state=$(fm_backend_paseo_endpoint_state "$FM_BACKEND_VALIDATED_TARGET" "fm-$id")
  case "$endpoint_state" in
    gone) ;;
    alive) return 1 ;;
    *) echo "recovery: $id endpoint absence is unproved; copy retained" >&2; return 1 ;;
  esac
  if out=$(fm_run_timed 40 env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --return-copy 2>&1); then
    printf '%s\n' "$out" >&2
    printf '%s\n' "$out" | grep -F "copy-return: released $id;" >/dev/null
  else
    printf '%s\n' "$out" >&2
    return 1
  fi
}

case "${1:-}" in
  --help|-h) echo 'usage: fm-treehouse-recover.sh task <id> | pool <project-dir>'; exit 0 ;;
  task) [ "$#" = 2 ] || exit 2; recover_task "$2" ;;
  pool)
    [ "$#" = 2 ] && [ -d "$2" ] || exit 2
    # This read never allocates, returns, starts a daemon or scans endpoints.
    inventory=$(cd "$2" && fm_run_timed 5 treehouse status --json 2>/dev/null) || exit 1
    printf '%s' "$inventory" | jq -e 'type == "array" and all(.[]; .path | type == "string")' >/dev/null || exit 1
    pools=$(printf '%s' "$inventory" | jq -r '.[].path')
    [ -n "$pools" ] || exit 1
    deadline=$(( $(date +%s) + 30 ))
    visited=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$visited" -lt 32 ] && [ "$(date +%s)" -lt "$deadline" ] || break
      visited=$((visited + 1))
      if recover_task "$(basename "$meta" .meta)" "$pools"; then exit 0; fi
    done
    exit 1 ;;
  *) echo 'usage: fm-treehouse-recover.sh task <id> | pool <project-dir>' >&2; exit 2 ;;
esac
