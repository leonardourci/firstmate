#!/usr/bin/env bash
# Live driver against the real Paseo 0.8.0 daemon: builds throwaway projects,
# opens a REAL Paseo terminal tab in a human-titled workspace, runs
# inside-paseo-tab.sh inside it, then verifies placement from Paseo's own
# workspace/terminal listings and removes everything it created.
set -u
ROOT=$1
E=$(cd "$(dirname "$0")" && pwd)
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-live-P.XXXXXX")   # raw path (doubled slash under $TMPDIR)
Q=$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-live-Q.XXXXXX")
PL=$(cd "$P" && pwd); PR=$(cd "$P" && pwd -P); QL=$(cd "$Q" && pwd); QR=$(cd "$Q" && pwd -P)
WS_ALL=""
cleanup() {
  local w prj
  for w in $WS_ALL $(paseo workspace ls --json 2>/dev/null | jq -r --arg a "$PL" --arg b "$PR" --arg c "$QL" --arg d "$QR" \
      '.[]? | select(.cwd == $a or .cwd == $b or .cwd == $c or .cwd == $d) | .workspaceId'); do
    paseo workspace archive "$w" >/dev/null 2>&1 || true
  done
  for prj in $(paseo project ls --json 2>/dev/null | jq -r --arg a "$PL" --arg b "$PR" --arg c "$QL" --arg d "$QR" \
      '.[]? | select(.path == $a or .path == $b or .path == $c or .path == $d) | .projectId'); do
    paseo project delete "$prj" >/dev/null 2>&1 || true
  done
  rm -rf "$P" "$Q"
}
trap cleanup EXIT

echo "projects before: $(paseo project ls --json | jq -c '[.[].path]')"
WKS_OWN=$(paseo workspace create --path "$P" --isolation local --title "fm-test captain tab" --json | jq -r .workspaceId)
WKS_TITLED=$(paseo workspace create --path "$P" --isolation local --title firstmate --json | jq -r .workspaceId)
WS_ALL="$WKS_OWN $WKS_TITLED"
echo "P=$P  (logical $PL)"
echo "Q=$Q"
echo "own (human-titled) workspace for P: $WKS_OWN"
echo "competing 'firstmate'-titled workspace for P: $WKS_TITLED"
TAB=$(paseo terminal create --workspace "$WKS_OWN" --cwd "$P" --name fm-test-captain --json | jq -r .id)
echo "captain tab terminal: $TAB"
sleep 1
paseo terminal send-keys "$TAB" -l -- "bash '$E/inside-paseo-tab.sh' '$ROOT' '$P' '$Q' '$WKS_TITLED' > '$E/inside-paseo-tab.log' 2>&1; tail -1 '$E/inside-paseo-tab.log'" >/dev/null
paseo terminal send-keys "$TAB" Enter >/dev/null
for _ in $(seq 1 400); do
  grep -q DRIVER-DONE "$E/inside-paseo-tab.log" 2>/dev/null && break
  sleep 1
done
sleep 0.5
echo "in-tab driver elapsed: ${SECONDS}s"; paseo terminal capture "$TAB" > "$E/paseo-captain-tab-capture.txt" 2>&1

echo
echo "== Paseo's own view after the run =="
WS_JSON=$(paseo workspace ls --json)
TERM_JSON=$(paseo terminal ls --all --json)
printf '%s' "$WS_JSON" | jq -c --arg a "$PL" --arg b "$PR" --arg c "$QL" --arg d "$QR" \
  '[.[]? | select(.cwd == $a or .cwd == $b or .cwd == $c or .cwd == $d) | {workspaceId,name,cwd}]'
WS_IDS=$(printf '%s' "$WS_JSON" | jq -c --arg a "$PL" --arg b "$PR" --arg c "$QL" --arg d "$QR" \
  '[.[]? | select(.cwd == $a or .cwd == $b or .cwd == $c or .cwd == $d) | .workspaceId]')
echo "terminals in those workspaces:"
printf '%s' "$TERM_JSON" | jq -c --argjson ws "$WS_IDS" '.[]? | select(.workspaceId as $w | $ws | index($w)) | {id,name,workspaceId}'
echo "projects during: $(paseo project ls --json | jq -c '[.[].path]')"
cleanup
trap - EXIT
echo "projects after cleanup: $(paseo project ls --json | jq -c '[.[].path]')"
echo "leftover fm-test terminals: $(paseo terminal ls --all --json | jq -c '[.[]? | select(.name | test("fm-test")) | .name]')"
