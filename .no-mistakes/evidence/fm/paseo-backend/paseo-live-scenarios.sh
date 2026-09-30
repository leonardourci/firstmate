#!/usr/bin/env bash
# Live scenarios for the paseo workspace-placement/retire behavior, driven
# against the REAL Paseo daemon through the adapter in the run worktree.
# Uses a disposable lab FM_HOME; creates only fm-labtest-* terminals and
# workspaces/projects under the lab or a throwaway tmp dir; cleans up.
set -u
WT=${WT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
LAB=$(cd "$LAB" && pwd)
OUTSIDE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-outside.XXXXXX")" && pwd)
export FM_HOME=$LAB FM_ROOT=$WT
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID PASEO_TERMINAL_ID
mkdir -p "$LAB/projects/demo" "$LAB/projects/demo2"
. "$WT/bin/fm-backend.sh"
fm_backend_source paseo
P() { fm_backend_paseo_cli "$@"; }
ws_json() { P workspace ls --json; }
ws_name() { ws_json | jq -r --arg id "$1" '.[] | select(.workspaceId==$id) | .name'; }
ws_alive() { [ -n "$(ws_name "$1")" ]; }
prj_for() { P project ls --json | jq -r --arg p "$1" '.[] | select(.path==$p) | .projectId' | head -1; }
FAILS=0
ok() { printf 'PASS - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
CREATED_WS=()
cleanup() {
  local w p d
  for w in "${CREATED_WS[@]:-}"; do [ -n "$w" ] && P workspace archive "$w" >/dev/null 2>&1; done
  for t in $(P terminal ls --all --json | jq -r '.[] | select(.name|test("labtest")) | .id'); do P terminal kill "$t" >/dev/null 2>&1; done
  for d in "$LAB/projects/demo" "$LAB/projects/demo2" "$LAB" "$OUTSIDE"; do
    for w in $(ws_json | jq -r --arg c "$d" '.[] | select(.cwd==$c) | .workspaceId'); do P workspace archive "$w" >/dev/null 2>&1; done
    p=$(prj_for "$d"); [ -n "$p" ] && P project delete "$p" >/dev/null 2>&1
  done
  rm -rf "$LAB" "$OUTSIDE"
}
trap cleanup EXIT
echo "paseo $(P --version)  FM_HOME=$LAB"
echo

echo "== S1 fallback: firstmate outside Paseo gets per-project 'firstmate' workspace; last close archives it and deletes its project"
read -r T1 W1 <<<"$(fm_backend_paseo_create_task fm-labtest-a "$LAB/projects/demo")"
echo "  created terminal=$T1 workspace=$W1 title='$(ws_name "$W1")' project=$(prj_for "$LAB/projects/demo")"
[ "$(ws_name "$W1")" = firstmate ] && [ -n "$(prj_for "$LAB/projects/demo")" ] && ok "S1 spawn created 'firstmate' workspace + project for demo" || bad "S1 spawn"
fm_backend_paseo_kill "$T1:$W1" "" fm-labtest-a
sleep 0.5
echo "  after kill: workspace alive? $(ws_alive "$W1" && echo yes || echo no); project=$(prj_for "$LAB/projects/demo")"
! ws_alive "$W1" && [ -z "$(prj_for "$LAB/projects/demo")" ] && ok "S1 last close archived workspace and deleted project" || bad "S1 retire"
echo

echo "== S2 guard: sibling tab holds the shared workspace back; closing the last one retires"
read -r T2 W2 <<<"$(fm_backend_paseo_create_task fm-labtest-b1 "$LAB/projects/demo")"
read -r T3 W3 <<<"$(fm_backend_paseo_create_task fm-labtest-b2 "$LAB/projects/demo")"
[ "$W2" = "$W3" ] && ok "S2 second task is a sibling tab in same workspace" || bad "S2 same workspace ($W2 vs $W3)"
fm_backend_paseo_kill "$T2:$W2" "" fm-labtest-b1; sleep 0.5
ws_alive "$W2" && [ -n "$(prj_for "$LAB/projects/demo")" ] && ok "S2 first close kept workspace+project (sibling tab alive)" || bad "S2 held back"
fm_backend_paseo_kill "$T3:$W3" "" fm-labtest-b2; sleep 0.5
! ws_alive "$W2" && [ -z "$(prj_for "$LAB/projects/demo")" ] && ok "S2 last close retired workspace+project" || bad "S2 final retire"
echo

echo "== S3 adversarial: tab already closed by captain in Paseo; teardown kill still retires the recorded workspace"
read -r T4 W4 <<<"$(fm_backend_paseo_create_task fm-labtest-c "$LAB/projects/demo")"
P terminal kill "$T4" >/dev/null 2>&1; sleep 0.5
echo "  tab closed directly via 'paseo terminal kill'; workspace alive? $(ws_alive "$W4" && echo yes || echo no)"
fm_backend_paseo_kill "$T4:$W4" "" fm-labtest-c; rc=$?; sleep 0.5
[ $rc -eq 0 ] && ! ws_alive "$W4" && [ -z "$(prj_for "$LAB/projects/demo")" ] && ok "S3 kill rc=0 and gone-tab workspace+project retired" || bad "S3 gone-tab retire rc=$rc"
echo

echo "== S4 guard: project folder outside FM_HOME/projects is archived-workspace-only, project never deleted"
read -r T5 W5 <<<"$(fm_backend_paseo_create_task fm-labtest-d "$OUTSIDE")"
PRJ_OUT=$(prj_for "$OUTSIDE")
fm_backend_paseo_kill "$T5:$W5" "" fm-labtest-d; sleep 0.5
! ws_alive "$W5" && [ -n "$PRJ_OUT" ] && [ "$(prj_for "$OUTSIDE")" = "$PRJ_OUT" ] && ok "S4 workspace archived, outside project $PRJ_OUT kept" || bad "S4 outside project"
echo

echo "== S5 terminal-tab primary (PASEO_WORKSPACE_ID): tab lands in own workspace whatever the project; closing keeps own workspace"
OWN=$(P workspace create --path "$LAB" --isolation local --title firstmate --json | jq -r .workspaceId); CREATED_WS+=("$OWN")
echo "  own workspace=$OWN cwd=$LAB title=firstmate"
WS_BEFORE=$(ws_json | jq length); PRJ_BEFORE=$(P project ls --json | jq length)
read -r T6 W6 <<<"$(PASEO_WORKSPACE_ID=$OWN fm_backend_paseo_create_task fm-labtest-e "$LAB/projects/demo2")"
[ "$W6" = "$OWN" ] && [ "$(ws_json | jq length)" = "$WS_BEFORE" ] && [ "$(P project ls --json | jq length)" = "$PRJ_BEFORE" ] && [ -z "$(prj_for "$LAB/projects/demo2")" ] \
  && ok "S5 demo2 task tab placed in own workspace; no new workspace/project" || bad "S5 placement W6=$W6"
PASEO_WORKSPACE_ID=$OWN fm_backend_paseo_kill "$T6:$W6" "" fm-labtest-e; sleep 0.5
ws_alive "$OWN" && ok "S5 closing the last task tab kept own workspace (even titled 'firstmate')" || bad "S5 own workspace archived!"
echo

echo "== S6 agent primary (PASEO_AGENT_ID only): unique workspace with cwd=FM_HOME is adopted"
read -r T7 W7 <<<"$(PASEO_AGENT_ID=agent-labtest fm_backend_paseo_create_task fm-labtest-f "$LAB/projects/demo2")"
[ "$W7" = "$OWN" ] && ok "S6 agent-only primary adopted home workspace $OWN" || bad "S6 W7=$W7"
PASEO_AGENT_ID=agent-labtest fm_backend_paseo_kill "$T7:$W7" "" fm-labtest-f; sleep 0.5
ws_alive "$OWN" && ok "S6 own workspace kept after close" || bad "S6 own archived"
echo

echo "== S7 adversarial: two workspaces at FM_HOME are ambiguous -> falls back to per-project workspace, retired on close"
OWN2=$(P workspace create --path "$LAB" --isolation local --title other-lab --json | jq -r .workspaceId); CREATED_WS+=("$OWN2")
read -r T8 W8 <<<"$(PASEO_AGENT_ID=agent-labtest fm_backend_paseo_create_task fm-labtest-g "$LAB/projects/demo2")"
[ "$W8" != "$OWN" ] && [ "$W8" != "$OWN2" ] && [ "$(ws_name "$W8")" = firstmate ] && ok "S7 ambiguous home -> fallback 'firstmate' workspace $W8 for demo2" || bad "S7 W8=$W8"
PASEO_AGENT_ID=agent-labtest fm_backend_paseo_kill "$T8:$W8" "" fm-labtest-g; sleep 0.5
! ws_alive "$W8" && [ -z "$(prj_for "$LAB/projects/demo2")" ] && ws_alive "$OWN" && ws_alive "$OWN2" && ok "S7 fallback retired; both home workspaces untouched" || bad "S7 retire"
echo

echo "== S8 explicit-only: ambient Paseo markers never select paseo"
b=$(env PASEO_AGENT_ID=x PASEO_WORKSPACE_ID=y __CFBundleIdentifier=sh.paseo.desktop FM_BACKEND= FM_BACKEND_CONFIG_DIR="$LAB/config" TMUX= HERDR_ENV= CMUX_WORKSPACE_ID= bash -c ". '$WT/bin/fm-backend.sh'; fm_backend_name" 2>/dev/null)
echo "  fm_backend_name with PASEO_* markers + paseo bundle id, no selection -> '$b'"
[ "$b" != paseo ] && ok "S8 not auto-detected ($b)" || bad "S8 autodetected paseo"
b2=$(env FM_BACKEND=paseo bash -c ". '$WT/bin/fm-backend.sh'; fm_backend_name" 2>&1 | tail -1)
echo "  FM_BACKEND=paseo -> '$b2'"
[ "$b2" = paseo ] && ok "S8 explicit FM_BACKEND=paseo selects paseo" || bad "S8 explicit"
echo
echo "FAILS=$FAILS"
exit $FAILS
