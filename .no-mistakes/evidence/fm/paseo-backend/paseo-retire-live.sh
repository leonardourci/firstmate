#!/usr/bin/env bash
# Live Paseo workspace-retirement scenarios against the real Paseo daemon,
# inside a disposable lab FM_HOME. Usage: paseo-retire-live.sh <fm-root> <lab-home>
set -u
ROOT=$1
LAB=$(cd "$2" && pwd) || exit 2
export FM_HOME=$LAB FM_ROOT=$ROOT STATE=$LAB/state
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paseo || exit 2
P=$LAB/projects/demo
mkdir -p "$P" && git -C "$P" init -q
OUT_RAW=$(mktemp -d "${TMPDIR:-/tmp}/fm-outside.XXXXXX")
OUT=$(cd "$OUT_RAW" && pwd)
ws_alive() { paseo workspace ls --json | jq -r --arg id "$1" '.[]|select(.workspaceId==$id)|.workspaceId'; }
proj_for() { paseo project ls --json | jq -r --arg p "$1" '.[]|select(.path==$p)|.projectId'; }
cleanup() {
  local w d pr
  for w in ${WSA:-} ${WSO:-} ${WSB:-}; do [ -z "$(ws_alive "$w")" ] || paseo workspace archive "$w" >/dev/null 2>&1; done
  for d in "$P" "$OUT" "$LAB/projects/demo2"; do pr=$(proj_for "$d"); [ -z "$pr" ] || paseo project delete "$pr" >/dev/null 2>&1; done
  rm -rf "$OUT_RAW"
}
trap cleanup EXIT

echo "== S1: two tasks in a home clone share one 'firstmate' workspace"
read -r T1 WSA <<<"$(fm_backend_paseo_create_task fm-lab1 "$P")"
read -r T2 WS2 <<<"$(fm_backend_paseo_create_task fm-lab2 "$P")"
echo "task1=$T1:$WSA task2=$T2:$WS2 project=$(proj_for "$P") title=$(paseo workspace ls --json | jq -r --arg id "$WSA" '.[]|select(.workspaceId==$id)|.name')"
[ "$WSA" = "$WS2" ] && echo "PASS same workspace" || echo "FAIL different workspaces"

echo "== S2: kill first tab (sibling remains) -> workspace stays"
fm_backend_paseo_kill "$T1:$WSA" "" fm-lab1
[ -n "$(ws_alive "$WSA")" ] && echo "PASS workspace still live after first kill" || echo "FAIL workspace archived with sibling tab live"

echo "== S3: last tab closed outside firstmate (tab already gone), then teardown kill with label"
paseo terminal kill "$T2" >/dev/null
fm_backend_paseo_kill "$T2:$WSA" "" fm-lab2
echo "kill rc=$?"
[ -z "$(ws_alive "$WSA")" ] && echo "PASS workspace archived" || echo "FAIL workspace $WSA still live"
[ -z "$(proj_for "$P")" ] && echo "PASS project for home clone deleted" || echo "FAIL project still registered"

echo "== S4 (adversarial): folder outside FM_HOME/projects -> last kill must NOT archive or delete"
read -r T3 WSO <<<"$(fm_backend_paseo_create_task fm-lab3 "$OUT")"
echo "outside project=$(proj_for "$OUT")"
fm_backend_paseo_kill "$T3:$WSO" "" fm-lab3
[ -n "$(ws_alive "$WSO")" ] && echo "PASS foreign-folder workspace kept" || echo "FAIL foreign workspace archived"
[ -n "$(proj_for "$OUT")" ] && echo "PASS foreign project kept" || echo "FAIL foreign project deleted"

echo "== S5 (adversarial): Firstmate's own workspace (PASEO_WORKSPACE_ID) adopted and never retired"
mkdir -p "$LAB/projects/demo2" && git -C "$LAB/projects/demo2" init -q
read -r T4 WSB <<<"$(fm_backend_paseo_create_task fm-lab4 "$LAB/projects/demo2")"
export PASEO_WORKSPACE_ID=$WSB
read -r T5 WS5 <<<"$(fm_backend_paseo_create_task fm-lab5 "$P")"
[ "$WS5" = "$WSB" ] && echo "PASS task tab adopted firstmate's own workspace" || echo "FAIL tab went to $WS5 not own $WSB"
fm_backend_paseo_kill "$T4:$WSB" "" fm-lab4
fm_backend_paseo_kill "$T5:$WSB" "" fm-lab5
[ -n "$(ws_alive "$WSB")" ] && echo "PASS own workspace kept after its last task tab closed" || echo "FAIL own workspace archived"
unset PASEO_WORKSPACE_ID
