#!/usr/bin/env bash
# Before/after reproduction of the round-2 C-u finding against the REAL Paseo
# daemon: type a pending line into `cat -v`, send firstmate's C-u, then submit
# NEXT. Pre-fix adapter (45c122f) vs the change under test (7d7c626).
set -u
WT=${WT:?}
OLD=$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-old.XXXXXX")
git -C "$WT" archive 45c122f bin | tar -x -C "$OLD"
PROJ=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-cu.XXXXXX")" && pwd)
export FM_HOME="$OLD/home"; mkdir -p "$FM_HOME"
unset FM_BACKEND PASEO_AGENT_ID __CFBundleIdentifier
TIDS="" WSID=""
cleanup() {
  local t prj
  for t in $TIDS; do paseo terminal kill "$t" >/dev/null 2>&1 || true; done
  [ -z "$WSID" ] || paseo workspace archive "$WSID" >/dev/null 2>&1 || true
  for prj in $(paseo project ls --json 2>/dev/null | jq -r --arg a "$PROJ" --arg b "$(cd "$PROJ" && pwd -P)" '.[]? | select(.path == $a or .path == $b) | .projectId'); do
    paseo project delete "$prj" >/dev/null 2>&1 || true
  done
  rm -rf "$OLD" "$PROJ"
}
trap cleanup EXIT

run_case() { # <label> <root>
  (
    # shellcheck source=/dev/null
    . "$2/bin/fm-backend.sh"
    fm_backend_source paseo
    ids=$(fm_backend_paseo_create_task "fm-cu-$1" "$PROJ") || exit 1
    read -r tid wsid <<<"$ids"
    echo "$tid $wsid" >"$FM_HOME/$1.ids"
    t="$tid:$wsid"
    fm_backend_paseo_send_text_line "$t" "cat -v" "fm-cu-$1"; sleep 0.6
    fm_backend_paseo_send_literal "$t" "OLD-PROMPT" "fm-cu-$1"; sleep 0.3
    fm_backend_send_key paseo "$t" C-u "fm-cu-$1"; echo "send_key C-u rc=$?"
    sleep 0.3
    fm_backend_paseo_send_text_line "$t" "NEXT" "fm-cu-$1"; sleep 0.8
    echo "--- $1: tab tail ---"
    fm_backend_paseo_capture "$t" 3 "fm-cu-$1"; echo
  )
  read -r tid wsid <"$FM_HOME/$1.ids"; TIDS="$TIDS $tid"; WSID=$wsid
}
echo "### BEFORE (45c122f adapter)"; run_case before "$OLD"
echo "### AFTER (7d7c626 adapter, this change)"; run_case after "$WT"
