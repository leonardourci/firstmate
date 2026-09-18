#!/usr/bin/env bash
# Live driver for the Paseo backend (PR #4728) against the REAL Paseo 0.8.0
# daemon. Drives firstmate's public entry points (fm-backend dispatch,
# bin/fm-peek.sh, bin/fm-send.sh, bin/fm-control.sh) in an isolated FM_HOME
# with a throwaway project dir. A logging `paseo` shim records every CLI call
# so the run can prove the adapter never issued a `paseo project` command.
# Cleans up only what it created.
set -u
WT=${WT:?set WT to the firstmate checkout}
REAL_PASEO=$(command -v paseo)
SB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-live.XXXXXX")" && pwd)
LOG="$SB/paseo-calls.log"
mkdir -p "$SB/shim" "$SB/home/state" "$SB/home/config" "$SB/home/data"
cat >"$SB/shim/paseo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$LOG"
exec "$REAL_PASEO" "\$@"
EOF
chmod +x "$SB/shim/paseo"
export PATH="$SB/shim:$PATH"
export FM_HOME="$SB/home"
# Temp-sandbox fleet: use the documented test-harness escape hatch
# (bin/fm-gate-refuse-lib.sh) that firstmate's own suites export.
export FM_GATE_REFUSE_BYPASS=1
unset FM_BACKEND PASEO_AGENT_ID __CFBundleIdentifier TMUX HERDR_ENV CMUX_WORKSPACE_ID

# Throwaway project: PHYS is the resolved path, LOGICAL the /var symlinked
# form, RAW the doubled-slash form a $TMPDIR/ join produces.
PROJ_NAME="fm-paseo-live-proj.$$"
mkdir -p "${TMPDIR}$PROJ_NAME"
LOGICAL="${TMPDIR%/}/$PROJ_NAME"
RAW="${TMPDIR}/$PROJ_NAME"
PHYS=$(cd "$LOGICAL" && pwd -P)

PASS=0 FAILN=0
ok() { PASS=$((PASS + 1)); printf 'PASS - %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL - %s\n' "$1"; }
step() { printf '\n=== %s ===\n' "$1"; }

# shellcheck source=/dev/null
. "$WT/bin/fm-backend.sh"
fm_backend_source paseo || { echo "cannot source adapter"; exit 1; }

TIDS=""
WSID=""
cleanup() {
  local t prj
  for t in $TIDS; do "$REAL_PASEO" terminal kill "$t" >/dev/null 2>&1 || true; done
  [ -z "$WSID" ] || "$REAL_PASEO" workspace archive "$WSID" >/dev/null 2>&1 || true
  for prj in $("$REAL_PASEO" project ls --json 2>/dev/null | jq -r --arg a "$LOGICAL" --arg b "$PHYS" '.[]? | select(.path == $a or .path == $b) | .projectId'); do
    "$REAL_PASEO" project delete "$prj" >/dev/null 2>&1 || true
  done
  rm -rf "$PHYS" "$SB"
}
trap cleanup EXIT

seed_meta() { # <id> <tid> <wsid> <harness>
  cat >"$FM_HOME/state/$1.meta" <<EOF
window=$2:$3
endpoint_task_id=$1
worktree=$LOGICAL
project=$LOGICAL
harness=$4
kind=ship
mode=local-only
yolo=off
backend=paseo
paseo_terminal_id=$2
paseo_workspace_id=$3
EOF
}

step "S1 container shape: one shared 'firstmate' workspace, one tab per task, adopted across raw/logical/physical paths"
PROJ_BEFORE=$("$REAL_PASEO" project ls --json 2>/dev/null | jq -r 'length')
fm_backend_paseo_container_ensure || { echo "container_ensure failed"; exit 1; }
IDS_A=$(fm_backend_paseo_create_task fm-livea "$PHYS") || { bad "create task A"; exit 1; }
read -r TA WA <<<"$IDS_A"; TIDS="$TIDS $TA"; WSID=$WA
IDS_B=$(fm_backend_paseo_create_task fm-liveb "$LOGICAL") || { bad "create task B"; exit 1; }
read -r TB WB <<<"$IDS_B"; TIDS="$TIDS $TB"
IDS_C=$(fm_backend_paseo_create_task fm-livec "$RAW") || { bad "create task C"; exit 1; }
read -r TC WC <<<"$IDS_C"; TIDS="$TIDS $TC"
echo "task A: terminal=$TA workspace=$WA (created from physical $PHYS)"
echo "task B: terminal=$TB workspace=$WB (created from logical $LOGICAL)"
echo "task C: terminal=$TC workspace=$WC (created from raw $RAW)"
if [ "$WA" = "$WB" ] && [ "$WB" = "$WC" ]; then ok "three tasks share ONE workspace across physical/logical/doubled-slash paths"; else bad "tasks landed in different workspaces"; fi
echo "--- paseo workspace ls (this project) ---"
"$REAL_PASEO" workspace ls --json 2>/dev/null | jq -c --arg a "$LOGICAL" --arg b "$PHYS" '.[] | select(.cwd == $a or .cwd == $b) | {workspaceId, name, cwd}'
NWS=$("$REAL_PASEO" workspace ls --json 2>/dev/null | jq -r --arg a "$LOGICAL" --arg b "$PHYS" '[.[] | select(.cwd == $a or .cwd == $b)] | length')
WSNAME=$("$REAL_PASEO" workspace ls --json 2>/dev/null | jq -r --arg id "$WA" '.[] | select(.workspaceId == $id) | .name')
[ "$NWS" = 1 ] && [ "$WSNAME" = firstmate ] && ok "exactly one workspace for the project, titled 'firstmate'" || bad "workspace count=$NWS title=$WSNAME"
echo "--- paseo terminal ls (workspace $WA) ---"
"$REAL_PASEO" terminal ls --all --json 2>/dev/null | jq -c --arg w "$WA" '.[] | select(.workspaceId == $w) | {id, name, workspaceId}'
NTERM=$("$REAL_PASEO" terminal ls --all --json 2>/dev/null | jq -r --arg w "$WA" '[.[] | select(.workspaceId == $w)] | length')
HOME_LABEL=$(fm_backend_paseo_home_label)
NAMED=$("$REAL_PASEO" terminal ls --all --json 2>/dev/null | jq -r --arg w "$WA" --arg p "fm-$HOME_LABEL-" '[.[] | select(.workspaceId == $w and (.name | startswith($p)))] | length')
[ "$NAMED" = 3 ] && ok "three task tabs named fm-$HOME_LABEL-<id> in that workspace (total tabs in workspace: $NTERM)" || bad "expected 3 named task tabs, got $NAMED"
PROJ_AFTER=$("$REAL_PASEO" project ls --json 2>/dev/null | jq -r 'length')
NPROJ=$("$REAL_PASEO" project ls --json 2>/dev/null | jq -r --arg a "$LOGICAL" --arg b "$PHYS" '[.[] | select(.path == $a or .path == $b)] | length')
echo "paseo projects: before=$PROJ_BEFORE after=$PROJ_AFTER (for this path: $NPROJ)"
[ "$NPROJ" = 1 ] && [ "$PROJ_AFTER" = $((PROJ_BEFORE + 1)) ] && ok "Paseo registered exactly one project for the path (no multiplication)" || bad "project count changed unexpectedly"

seed_meta livea "$TA" "$WA" claude
seed_meta liveb "$TB" "$WA" muse
seed_meta livec "$TC" "$WA" claude

step "S2 fm-peek.sh reads the task tab by task id"
fm_backend_paseo_send_text_line "$TA:$WA" "echo peek-marker-livea" fm-livea
sleep 0.8
PEEK=$("$WT/bin/fm-peek.sh" livea 15 2>&1)
printf '%s\n' "$PEEK" | tail -n 6
case "$PEEK" in *peek-marker-livea*) ok "fm-peek.sh livea shows the task tab's output" ;; *) bad "fm-peek.sh did not show the task tab output" ;; esac

step "S3 fm-send.sh text steer: durable inbox record + doorbell rung into the task tab"
fm_backend_paseo_send_text_line "$TA:$WA" "cat" fm-livea
sleep 0.5
SEND_OUT=$("$WT/bin/fm-send.sh" livea "live steer from the paseo driver" 2>&1); SEND_RC=$?
echo "fm-send rc=$SEND_RC"; printf '%s\n' "$SEND_OUT" | tail -n 5
sleep 1
INBOX=$(find "$FM_HOME/state/livea.inbox" -type f 2>/dev/null | head -5)
echo "inbox files:"; printf '%s\n' "$INBOX"
PEEK=$("$WT/bin/fm-peek.sh" livea 8 2>&1)
echo "--- tab tail after send ---"; printf '%s\n' "$PEEK"
if [ "$SEND_RC" = 0 ] && [ -n "$INBOX" ] && grep -rq "live steer from the paseo driver" "$FM_HOME/state/livea.inbox" 2>/dev/null; then ok "fm-send.sh recorded the steer durably (rc=0)"; else bad "fm-send durable record missing (rc=$SEND_RC)"; fi
case "$PEEK" in *inbox*|*steer*|*Steer*|*message*) ok "doorbell line landed in the Paseo tab" ;; *) bad "doorbell not visible in tab" ;; esac
fm_backend_paseo_send_key "$TA:$WA" C-c fm-livea

step "S4 C-u clears the line (raw 0x15), never typed as literal 'C-u' text (fm-control.sh interrupt, harness muse = Escape + C-u)"
TB_T="$TB:$WA"
fm_backend_paseo_send_text_line "$TB_T" "cat -v" fm-liveb
sleep 0.6
fm_backend_paseo_send_literal "$TB_T" "RESTORED-OLD-PROMPT" fm-liveb
sleep 0.3
CTL_OUT=$("$WT/bin/fm-control.sh" liveb interrupt 2>&1); CTL_RC=$?
echo "fm-control.sh liveb interrupt rc=$CTL_RC: $CTL_OUT"
sleep 0.3
fm_backend_paseo_send_text_line "$TB_T" "NEXT-STEER" fm-liveb
sleep 0.8
CAP=$("$WT/bin/fm-peek.sh" liveb 6 2>&1)
echo "--- tab tail (cat -v echoes what the tty line discipline delivered) ---"; printf '%s\n' "$CAP"
[ "$CTL_RC" = 0 ] && ok "fm-control.sh interrupt succeeded on paseo for a muse task" || bad "fm-control.sh interrupt failed on paseo"
if printf '%s\n' "$CAP" | grep -qx 'NEXT-STEER' && ! printf '%s' "$CAP" | grep -q 'C-u'; then ok "the restored prompt was cleared: cat received only NEXT-STEER, no literal 'C-u'"; else bad "restored prompt not cleared or literal C-u typed"; fi

step "S5 fm-send.sh --key Escape on a muse task also clears with C-u"
fm_backend_paseo_send_literal "$TB_T" "SECOND-OLD-PROMPT" fm-liveb
sleep 0.3
KEY_OUT=$("$WT/bin/fm-send.sh" liveb --key Escape 2>&1); KEY_RC=$?
echo "fm-send.sh liveb --key Escape rc=$KEY_RC $KEY_OUT"
sleep 0.3
fm_backend_paseo_send_text_line "$TB_T" "SECOND-STEER" fm-liveb
sleep 0.8
CAP=$("$WT/bin/fm-peek.sh" liveb 6 2>&1)
printf '%s\n' "$CAP"
if [ "$KEY_RC" = 0 ] && printf '%s\n' "$CAP" | grep -qx 'SECOND-STEER' && ! printf '%s' "$CAP" | grep -q 'SECOND-OLD-PROMPT.*SECOND-STEER'; then ok "fm-send --key Escape + auto C-u cleared the composer"; else bad "fm-send --key Escape did not clear"; fi

step "S6 adversarial: an unsupported key is refused, not typed as text"
UNS_OUT=$("$WT/bin/fm-send.sh" liveb --key F5 2>&1); UNS_RC=$?
echo "fm-send.sh liveb --key F5 rc=$UNS_RC: $UNS_OUT"
fm_backend_paseo_send_text_line "$TB_T" "AFTER-F5" fm-liveb
sleep 0.8
CAP=$("$WT/bin/fm-peek.sh" liveb 4 2>&1); printf '%s\n' "$CAP"
if [ "$UNS_RC" != 0 ] && [ "$UNS_RC" != 3 ] && printf '%s' "$UNS_OUT" | grep -q "unsupported paseo key 'F5'" && printf '%s\n' "$CAP" | grep -qx 'AFTER-F5'; then ok "F5 refused loudly (rc=$UNS_RC) and nothing literal reached the tab"; else bad "unsupported key was not refused cleanly"; fi
fm_backend_paseo_send_key "$TB_T" C-c fm-liveb

step "S7 fm-control.sh interrupt on a claude task (Escape) succeeds on paseo"
CTL2=$("$WT/bin/fm-control.sh" livea interrupt 2>&1); CTL2_RC=$?
echo "rc=$CTL2_RC: $CTL2"
[ "$CTL2_RC" = 0 ] && ok "claude interrupt delivered on paseo" || bad "claude interrupt refused on paseo"

step "S8 routing authority: stale recorded terminal id recovers by NAME; a reused id under the wrong name is refused"
seed_meta livec bogus-terminal-0000 "$WA" claude
fm_backend_paseo_send_text_line "$TC:$WA" "echo recovered-by-name-livec" fm-livec
sleep 0.8
PEEK=$("$WT/bin/fm-peek.sh" livec 6 2>&1); PEEK_RC=$?
echo "fm-peek.sh livec (meta records bogus id) rc=$PEEK_RC"; printf '%s\n' "$PEEK" | tail -n 3
case "$PEEK" in *recovered-by-name-livec*) ok "stale terminal id recovered by home-scoped terminal NAME" ;; *) bad "name recovery failed" ;; esac
# Task 'imposter' records task A's live terminal id; the expected name fm-<home>-imposter does not match.
seed_meta imposter "$TA" "$WA" claude
IMP=$("$WT/bin/fm-send.sh" imposter --key Enter 2>&1); IMP_RC=$?
echo "fm-send.sh imposter --key Enter rc=$IMP_RC: $IMP"
IMP_PEEK=$("$WT/bin/fm-peek.sh" imposter 3 2>&1); IMP_PEEK_RC=$?
echo "fm-peek.sh imposter rc=$IMP_PEEK_RC"
[ "$IMP_RC" != 0 ] && [ "$IMP_RC" != 3 ] && [ "$IMP_PEEK_RC" != 0 ] && ok "a live terminal id recorded under another task's name is never targeted" || bad "imposter id was targeted"

step "S9 kill closes only the task tab; sibling tabs and the shared workspace survive"
fm_backend_kill paseo "$TA:$WA" "" fm-livea
sleep 0.8
LIVE_IDS=$("$REAL_PASEO" terminal ls --all --json 2>/dev/null | jq -r '.[].id')
WS_LIVE=$("$REAL_PASEO" workspace ls --json 2>/dev/null | jq -r --arg id "$WA" '.[] | select(.workspaceId == $id) | .workspaceId')
if ! printf '%s\n' "$LIVE_IDS" | grep -qx "$TA" && printf '%s\n' "$LIVE_IDS" | grep -qx "$TB" && printf '%s\n' "$LIVE_IDS" | grep -qx "$TC" && [ -n "$WS_LIVE" ]; then ok "task A tab closed; B and C tabs and workspace $WA alive"; else bad "kill scope wrong"; fi
fm_backend_kill paseo "$TA:$WA" "" fm-livea && ok "second kill of a gone tab stays best-effort (rc=0)" || bad "repeat kill errored"
echo "archive calls issued by the adapter: $(grep -c '^workspace archive' "$LOG" || true)"

step "S10 the adapter never ran a 'paseo project' command"
echo "--- distinct paseo subcommands issued during the run ---"
awk '{print $1, $2}' "$LOG" | sort | uniq -c
if grep -Eq '^project( |$)' "$LOG"; then bad "adapter issued a 'paseo project' command"; else ok "zero 'paseo project' invocations across $(wc -l <"$LOG" | tr -d ' ') paseo calls"; fi
grep -Eq '^workspace archive' "$LOG" && bad "adapter archived a workspace" || ok "adapter never archived the shared workspace"

printf '\nRESULT: %s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" = 0 ]
