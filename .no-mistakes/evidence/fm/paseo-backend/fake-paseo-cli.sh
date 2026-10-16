#!/usr/bin/env bash
# Disposable stateful stand-in for the external Paseo CLI (never the real daemon).
set -u
S="${FM_FAKE_PASEO_STATE:?}"
mkdir -p "$S"
[ -f "$S/ws.json" ] || echo '[]' > "$S/ws.json"
[ -f "$S/term.json" ] || echo '[]' > "$S/term.json"
{ for a in "$@"; do printf '%s ' "$a"; done; echo; } >> "$S/calls.log"
arg() { local want=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "${1:-} ${2:-}" in
  "-v "*) echo 0.9.2 ;;
  "status "*) echo '{"localDaemon":"running","connectedDaemon":"reachable"}' ;;
  "start "*) : ;;
  "workspace ls") cat "$S/ws.json" ;;
  "workspace create")
    id="wks_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    jq --arg id "$id" --arg n "$(arg --title "$@")" --arg c "$(arg --path "$@")" '. + [{workspaceId:$id,name:$n,cwd:$c}]' "$S/ws.json" > "$S/ws.tmp" && mv "$S/ws.tmp" "$S/ws.json"
    c="$(arg --path "$@")"; [ -f "$S/proj.json" ] || echo '[]' > "$S/proj.json"
    jq --arg c "$c" 'if any(.[]; .path == $c) then . else . + [{projectId:("prj_" + (length|tostring)), path:$c}] end' "$S/proj.json" > "$S/proj.tmp" && mv "$S/proj.tmp" "$S/proj.json"
    jq -n --arg id "$id" '{workspaceId:$id}' ;;
  "workspace archive") jq --arg id "$3" 'map(select(.workspaceId != $id))' "$S/ws.json" > "$S/ws.tmp" && mv "$S/ws.tmp" "$S/ws.json"; echo "archived $3" >> "$S/events.log" ;;
  "project ls") cat "$S/proj.json" 2>/dev/null || echo '[]' ;;
  "ls --json") echo '[]' ;;
  "project delete") echo "project-delete $3" >> "$S/events.log" ;;
  "terminal ls") cat "$S/term.json" ;;
  "terminal create")
    id="$(uuidgen | tr 'A-Z' 'a-z')"
    jq --arg id "$id" --arg w "$(arg --workspace "$@")" --arg n "$(arg --name "$@")" --arg c "$(arg --cwd "$@")" '. + [{id:$id,workspaceId:$w,name:$n,cwd:$c}]' "$S/term.json" > "$S/term.tmp" && mv "$S/term.tmp" "$S/term.json"
    jq -n --arg id "$id" '{id:$id}' ;;
  "terminal send-keys") shift 3; printf '%s\n' "$*" >> "$S/sends.log" ;;
  "terminal capture")
    jq -n --arg id "$3" --arg p "${FM_FAKE_PANE_PATH:-}" '{terminalId:$id, lines:["$ ", "__FM_PASEO_CWD_BEGIN__", $p, "__FM_PASEO_CWD_END__", "$ "], totalLines:5}' ;;
  "terminal kill") jq --arg id "$3" 'map(select(.id != $id))' "$S/term.json" > "$S/term.tmp" && mv "$S/term.tmp" "$S/term.json"; echo "killed $3" >> "$S/events.log" ;;
  *) echo "fake paseo: unhandled $*" >&2; exit 2 ;;
esac
