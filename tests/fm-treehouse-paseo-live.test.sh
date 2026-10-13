#!/usr/bin/env bash
# Token-free installed-tool guard for the actual Treehouse rendered failure,
# Paseo capture/rollback and a successful isolated allocation after return.
# Requires FM_TREEHOUSE_PASEO_HOME pointing to an empty, separately started
# test daemon. Never starts/restarts a daemon or touches a shared pool/daemon.
set -eu
unset FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE STATE
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID PASEO_HOST PASEO_HOME TREEHOUSE_ROOT
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# Paseo's binary can be bundled without being on PATH.
if ! command -v paseo >/dev/null 2>&1 && [ -x /Applications/Paseo.app/Contents/Resources/bin/paseo ]; then
  export PATH="/Applications/Paseo.app/Contents/Resources/bin:$PATH"
fi
fm_live_gate opt-in FM_TREEHOUSE_PASEO_LIVE paseo jq treehouse
# A generic FM_LIVE request must not opt this daemon-mutating guard in.
[ "${FM_TREEHOUSE_PASEO_LIVE:-0}" = 1 ] || {
  echo 'skip: live: opt-in; set FM_TREEHOUSE_PASEO_LIVE=1 with an isolated test home'
  exit 0
}
if [ -z "${FM_TREEHOUSE_PASEO_HOME:-}" ]; then
  if [ "${FM_TREEHOUSE_PASEO_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
    fail 'set FM_TREEHOUSE_PASEO_HOME to a separate test daemon home'
  fi
  echo 'skip: separate test daemon home not supplied (FM_TREEHOUSE_PASEO_HOME)'
  exit 0
fi
DAEMON_HOME=$(cd "$FM_TREEHOUSE_PASEO_HOME" && pwd -P)
case "$DAEMON_HOME/" in "$HOME/.paseo/"*) fail 'refusing the default Paseo home' ;; esac
TMP_ROOT=$(fm_test_tmproot fm-treehouse-paseo-live)
HOME_DIR="$TMP_ROOT/home"
# Route even production subprocesses through the explicit isolated home.
PASEO_BIN=$(command -v paseo)
mkdir -p "$TMP_ROOT/bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exec env -u PASEO_HOST -u PASEO_HOME %q --home %q "$@"\n' "$PASEO_BIN" "$DAEMON_HOME"
} > "$TMP_ROOT/bin/paseo"
chmod +x "$TMP_ROOT/bin/paseo"
export PATH="$TMP_ROOT/bin:$PATH"
export FM_HOME="$HOME_DIR"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paseo
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=tests/paseo-live-helpers.sh
. "$ROOT/tests/paseo-live-helpers.sh"
[ "$(fm_backend_paseo_daemon_state)" = ok ] || fail 'isolated test daemon unavailable'
# An occupied or ambiguous inventory cannot prove this is a disposable daemon.
for kind in workspace project; do
  inventory=$(fm_backend_paseo_cli "$kind" ls --json) || fail "cannot read isolated $kind inventory"
  printf '%s' "$inventory" | jq -e 'type == "array" and length == 0' >/dev/null || fail "test daemon has existing $kind records"
done
inventory=$(fm_backend_paseo_cli terminal ls --all --json) || fail 'cannot read isolated terminal inventory'
printf '%s' "$inventory" | jq -e 'type == "array" and length == 0' >/dev/null || fail 'test daemon has existing terminals'
inventory=$(fm_backend_paseo_cli ls --json) || fail 'cannot read isolated agent inventory'
printf '%s' "$inventory" | jq -e 'type == "array" and length == 0' >/dev/null || fail 'test daemon has existing agents'
version="$(treehouse --version) / Paseo $(paseo -v)"
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
WT=$(cd "$PROJ" && treehouse get --lease --no-fetch)
case "$WT" in "$POOL_ROOT"/.treehouse/*/*/*) ;; *) fail "pool isolation failed: $WT" ;; esac
fm_test_spawn_brief "$HOME_DIR" test-live-failed
# Create and record the workspace ourselves before any spawn can adopt it.
TARGET=''
WS=''
FM_TEST_PASEO_CLEANED=0
cleanup_live() {
  fm_test_paseo_cleanup_live "$TMP_ROOT" "$TMP_ROOT/created-workspace.json" "$TARGET" fm-test-live-success
}
trap cleanup_live EXIT
fm_backend_paseo_cli_json workspace create --path "$PROJ" --isolation local \
  --title "$(fm_backend_paseo_workspace_label)" --json > "$TMP_ROOT/created-workspace.json" || fail 'test workspace creation failed'
WS=$(jq -er '.workspaceId | strings | select(length > 0)' "$TMP_ROOT/created-workspace.json") || fail 'missing created workspace ID'
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
read -r tid task_ws <<< "$ids"
[ "$task_ws" = "$WS" ] || fail "task escaped this run's created workspace"
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
