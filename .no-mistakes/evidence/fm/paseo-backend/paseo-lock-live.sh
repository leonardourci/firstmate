#!/usr/bin/env bash
# Live driver: real Paseo daemon, disposable lab FM_HOME. Exercises the
# home-wide workspace lock between spawn (create_task) and cleanup (retire).
set -u
ROOT=${ROOT:?}
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB STATE=$LAB/state
CLONE=$LAB/projects/demo; mkdir -p "$CLONE"; git -C "$CLONE" init -q
OUTSIDE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-outside.XXXXXX")" && pwd)
. "$ROOT/bin/fm-backend.sh"; fm_backend_source paseo
LOCK=$(fm_backend_paseo_workspace_lock_path)
HOLDER=""; FAILS=0
ok(){ echo "PASS - $*"; }; bad(){ echo "FAIL - $*"; FAILS=$((FAILS+1)); }
ws_for(){ fm_backend_paseo_cli workspace ls --json 2>/dev/null | jq -r --arg a "$1" --arg b "$(cd "$1" && pwd -P)" '[.[]|select(.cwd==$a or .cwd==$b)|.workspaceId]|join(",")'; }
proj_for(){ fm_backend_paseo_cli project ls --json 2>/dev/null | jq -r --arg a "$1" --arg b "$(cd "$1" && pwd -P)" '[.[]|select(.path==$a or .path==$b)|.projectId]|join(",")'; }
term_named(){ fm_backend_paseo_cli terminal ls --all --json 2>/dev/null | jq -r --arg n "$1" '[.[]|select(.name==$n)|.id]|join(",")'; }
hold(){ bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_lock_try_acquire '$LOCK' || exit 9; echo held; sleep 120" > "$LAB/holder.out" 2>&1 & HOLDER=$!
  for _ in $(seq 50); do grep -q held "$LAB/holder.out" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
unhold(){ [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; rm -rf "$LOCK"; }
cleanup(){ unhold
  for d in "$CLONE" "$OUTSIDE"; do
    for t in $(fm_backend_paseo_cli terminal ls --all --json 2>/dev/null | jq -r '.[]|select(.name|startswith("fm-lablock"))|.id'); do fm_backend_paseo_cli terminal kill "$t" >/dev/null 2>&1; done
    for w in $(ws_for "$d" | tr , ' '); do fm_backend_paseo_cli workspace archive "$w" >/dev/null 2>&1; done
    for p in $(proj_for "$d" | tr , ' '); do fm_backend_paseo_cli project delete "$p" >/dev/null 2>&1; done
  done; rm -rf "$LAB" "$OUTSIDE"; }
trap cleanup EXIT
echo "lab FM_HOME=$LAB lock=$LOCK paseo=$(paseo --version)"

echo; echo "== S1 happy path: spawn in home clone, lock released, last-tab kill retires workspace+project"
ids=$(fm_backend_paseo_create_task fm-lablock-a "$CLONE") || bad "create_task failed"
read -r T1 W1 <<<"$ids"; echo "created terminal=$T1 workspace=$W1 project=$(proj_for "$CLONE")"
[ -e "$LOCK" ] && bad "lock still present after spawn" || ok "lock released after spawn"
fm_backend_paseo_kill "$T1:$W1" "" fm-lablock-a; sleep 0.5
echo "after kill: workspaces=[$(ws_for "$CLONE")] projects=[$(proj_for "$CLONE")] lock_exists=$([ -e "$LOCK" ] && echo yes || echo no)"
[ -z "$(ws_for "$CLONE")" ] && [ -z "$(proj_for "$CLONE")" ] && ok "workspace archived and clone project deleted" || bad "workspace/project not retired"

echo; echo "== S2 adversarial: another live process holds the lock -> spawn refuses, creates nothing"
hold || bad "holder did not take lock"; echo "holder pid=$HOLDER owns $LOCK"
start=$(date +%s)
err=$(FM_BACKEND_PASEO_LOCK_ATTEMPTS=20 fm_backend_paseo_create_task fm-lablock-b "$CLONE" 2>&1 >/dev/null); rc=$?
echo "create_task rc=$rc after $(( $(date +%s)-start ))s stderr: $err"
echo "state: terminals named fm-lablock-b=[$(term_named fm-lablock-b)] workspaces=[$(ws_for "$CLONE")] projects=[$(proj_for "$CLONE")]"
[ $rc -ne 0 ] && [ -z "$(term_named fm-lablock-b)" ] && [ -z "$(ws_for "$CLONE")" ] && ok "spawn refused under held lock and created nothing" || bad "spawn did not refuse cleanly"
unhold

echo; echo "== S3 adversarial: lock held during cleanup -> retire skips, workspace survives; retire after release archives"
ids=$(fm_backend_paseo_create_task fm-lablock-c "$CLONE") || bad "create_task failed"
read -r T3 W3 <<<"$ids"; echo "created terminal=$T3 workspace=$W3"
hold || bad "holder did not take lock"
FM_BACKEND_PASEO_LOCK_ATTEMPTS=20 fm_backend_paseo_kill "$T3:$W3" "" fm-lablock-c; rc=$?; sleep 0.5
echo "kill rc=$rc; terminal alive=[$(term_named fm-lablock-c)] workspaces=[$(ws_for "$CLONE")]"
[ $rc -eq 0 ] && [ -z "$(term_named fm-lablock-c)" ] && [ "$(ws_for "$CLONE")" = "$W3" ] && ok "tab closed, retire skipped under held lock, workspace kept" || bad "retire did not skip"
unhold
fm_backend_paseo_retire_workspace "$W3"; sleep 0.5
echo "after unlocked retire: workspaces=[$(ws_for "$CLONE")] projects=[$(proj_for "$CLONE")]"
[ -z "$(ws_for "$CLONE")" ] && [ -z "$(proj_for "$CLONE")" ] && ok "retire archives once lock is free" || bad "retire after release did not archive"

echo; echo "== S4 boundary: emptied firstmate workspace outside FM_HOME/projects is never archived"
ids=$(fm_backend_paseo_create_task fm-lablock-d "$OUTSIDE") || bad "create_task failed"
read -r T4 W4 <<<"$ids"; echo "created terminal=$T4 workspace=$W4 (cwd=$OUTSIDE)"
fm_backend_paseo_kill "$T4:$W4" "" fm-lablock-d; sleep 0.5
echo "after kill: terminal=[$(term_named fm-lablock-d)] workspaces=[$(ws_for "$OUTSIDE")] projects=[$(proj_for "$OUTSIDE")]"
[ -z "$(term_named fm-lablock-d)" ] && [ "$(ws_for "$OUTSIDE")" = "$W4" ] && ok "outside-home workspace kept after last tab closed" || bad "outside-home workspace touched"

echo; echo "== S5 concurrency: two spawns racing into the same clone serialize onto ONE workspace"
fm_backend_paseo_create_task fm-lablock-e1 "$CLONE" > "$LAB/e1" 2>&1 & p1=$!
fm_backend_paseo_create_task fm-lablock-e2 "$CLONE" > "$LAB/e2" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
echo "rc=$r1/$r2 e1=$(cat "$LAB/e1") e2=$(cat "$LAB/e2") workspaces=[$(ws_for "$CLONE")]"
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ "$(ws_for "$CLONE" | tr , '\n' | wc -l | tr -d ' ')" = 1 ] && ok "both tabs in one shared workspace" || bad "concurrent spawns split or failed"

echo; echo "FAILS=$FAILS"; exit $FAILS
