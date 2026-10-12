#!/usr/bin/env bash
# Token-free installed-tool guard for the actual Treehouse rendered failure,
# Paseo capture/rollback and a successful isolated allocation after return.
# Never starts/restarts a daemon or touches a real/shared worktree pool.
set -eu
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# Paseo's binary can be bundled without being on PATH.
if ! command -v paseo >/dev/null 2>&1 && [ -x /Applications/Paseo.app/Contents/Resources/bin/paseo ]; then
  export PATH="/Applications/Paseo.app/Contents/Resources/bin:$PATH"
fi
fm_live_gate default-on FM_TREEHOUSE_PASEO_LIVE paseo jq treehouse
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paseo
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
if [ "$(fm_backend_paseo_daemon_state)" != ok ]; then
  if [ "${FM_TREEHOUSE_PASEO_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
    fail "Paseo $(paseo -v): explicitly requested guard has no reachable daemon"
  fi
  echo 'skip: Paseo daemon unavailable; no daemon lifecycle action attempted'
  exit 0
fi
version="$(treehouse --version) / Paseo $(paseo -v)"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-paseo-live)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
POOL_ROOT="$TMP_ROOT/pool-root"
fm_test_spawn_home "$HOME_DIR" codex
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
fm_git_init_commit "$PROJ"
printf 'max_trees = 1\nroot = "%s"\n' "$POOL_ROOT" > "$PROJ/treehouse.toml"
git -C "$PROJ" add treehouse.toml
git -C "$PROJ" commit -qm 'isolated pool configuration'
# The resolved project and root must remain entirely within this test root.
case "$(cd "$PROJ" && pwd -P)/" in "$TMP_ROOT"/*) ;; *) fail 'project isolation failed' ;; esac
[ ! -e "$POOL_ROOT" ] || fail 'pool root was not exclusively created by this test'
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID TREEHOUSE_ROOT
WT=$(cd "$PROJ" && treehouse get --lease --no-fetch)
case "$WT" in "$POOL_ROOT"/.treehouse/*/*/*) ;; *) fail "pool isolation failed: $WT" ;; esac
fm_test_spawn_brief "$HOME_DIR" test-live-failed
FM_HOME="$HOME_DIR"
export FM_HOME
# Only terminal/workspace ids created in this isolated home are cleanup targets.
TARGET=''
WS=''
cleanup_live() {
  [ -z "$TARGET" ] || fm_backend_paseo_rollback_created "$TARGET" fm-test-live-success >/dev/null 2>&1 || true
  [ -z "$WS" ] || paseo workspace archive "$WS" >/dev/null 2>&1 || true
  local project_id
  project_id=$(paseo project ls --json | jq -r --arg path "$PROJ" '.[] | select(.path == $path) | .projectId')
  [ -z "$project_id" ] || paseo project delete "$project_id" >/dev/null 2>&1 || true
}
trap cleanup_live EXIT
before=$(date +%s)
if FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" test-live-failed "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$TMP_ROOT/failure" 2>&1; then
  fail "$version: full-pool spawn unexpectedly succeeded"
fi
output=$(cat "$TMP_ROOT/failure")
assert_contains "$output" 'all 1 worktrees are in use or dirty (max_trees = 1)' "$version: rendered allocator error missing"
[ $(( $(date +%s) - before )) -lt 30 ] || fail "$version: allocator error did not fail early"
name=$(fm_backend_paseo_scoped_name fm-test-live-failed)
[ -z "$(fm_backend_paseo_terminal_id_for_name "$name")" ] || fail "$version: created terminal was orphaned"
if FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" test-live-failed "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$TMP_ROOT/retry" 2>&1; then
  fail "$version: still-full retry unexpectedly succeeded"
fi
assert_no_grep 'already exists' "$TMP_ROOT/retry" "$version: orphan blocked retry"
pass "$version: actual pool-full text captured, early failure, exact created terminal closed and same-task retry permitted"
(cd "$PROJ" && treehouse return "$WT")
ids=$(fm_backend_paseo_create_task fm-test-live-success "$PROJ")
read -r tid WS <<< "$ids"
TARGET="$tid:$WS"
holder=$(fm_treehouse_task_lease_holder test-live-success "$HOME_DIR" test-generation)
fm_backend_paseo_send_text_line "$TARGET" "_fm_copy=\$(treehouse get --lease --no-fetch --lease-holder '$holder') && cd -- \"\$_fm_copy\"" fm-test-live-success
seen=''
for _ in $(seq 1 50); do
  seen=$(fm_backend_paseo_current_path "$TARGET" fm-test-live-success)
  [ "$seen" != "$WT" ] || break
  sleep 0.1
done
[ "$seen" = "$WT" ] || fail "$version: returned slot was not acquired by actual Paseo terminal"
native=$(fm_treehouse_slot_native_identity "$WT")
case "$native" in lease:*) ;; *) fail "$version: successful allocation has no native lease" ;; esac
[ "$(fm_treehouse_slot_native_holder "$WT")" = "$holder" ] || fail "$version: native task holder missing"
if (cd "$PROJ" && treehouse return --if-lease-id stale-lease "$WT") > "$TMP_ROOT/stale-return" 2>&1; then
  fail "$version: stale conditional return unexpectedly succeeded"
fi
[ "$(fm_treehouse_slot_native_identity "$WT")" = "$native" ] || fail "$version: stale return changed actual lease"
fm_backend_paseo_send_text_line "$TARGET" exit fm-test-live-success
sleep 0.5
fm_backend_paseo_rollback_created "$TARGET" fm-test-live-success || fail "$version: exact successful test terminal close failed"
TARGET=''
(cd "$PROJ" && treehouse return --if-lease-id "${native#lease:}" "$WT")
pass "$version: real terminal acquired durable task lease; stale return refused and exact conditional return succeeded"
cleanup_live
trap - EXIT
