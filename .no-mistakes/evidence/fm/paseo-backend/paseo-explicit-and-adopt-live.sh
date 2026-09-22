#!/usr/bin/env bash
# Live driver: explicit-only selection + own-workspace adoption against the real Paseo daemon.
set -u
ROOT=${ROOT:?}
. "$ROOT/bin/fm-backend.sh"
CFG=$(mktemp -d); CFGP=$(mktemp -d); printf 'paseo\n' >"$CFGP/backend"
sel() { env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID "$@" bash -c '. "$0/bin/fm-backend.sh"; v=$(fm_backend_name 2>/tmp/fm-sel-err.$$); echo "backend=$v stderr=[$(cat /tmp/fm-sel-err.$$)]"; rm -f /tmp/fm-sel-err.$$' "$ROOT"; }
echo "== S1 ambient Paseo markers, no config -> tmux, silent"
sel PASEO_AGENT_ID=agent-live PASEO_TERMINAL_ID=term-live PASEO_WORKSPACE_ID=wks-live __CFBundleIdentifier=sh.paseo.desktop FM_BACKEND= FM_CONFIG_OVERRIDE="$CFG"
sel PASEO_TERMINAL_ID=term-live PASEO_WORKSPACE_ID=wks-live FM_BACKEND= FM_CONFIG_OVERRIDE="$CFG"
sel __CFBundleIdentifier=sh.paseo.desktop FM_BACKEND= FM_CONFIG_OVERRIDE="$CFG"
echo "== S2 explicit selection -> paseo"
sel FM_BACKEND=paseo FM_CONFIG_OVERRIDE="$CFG"
sel FM_BACKEND= FM_CONFIG_OVERRIDE="$CFGP"
fm_backend_source paseo
P1=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-own.XXXXXX")" && pwd)
P2=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-oth.XXXXXX")" && pwd)
cleanup() {
  for w in ${OWN:-} ${WS2:-}; do fm_backend_paseo_cli workspace archive "$w" >/dev/null 2>&1; done
  for p in "$P1" "$P2"; do
    prj=$(fm_backend_paseo_cli project ls --json | jq -r --arg p "$p" --arg r "$(cd "$p" && pwd -P)" '.[]?|select(.path==$p or .path==$r)|.projectId' | head -1)
    [ -z "$prj" ] || fm_backend_paseo_cli project delete "$prj" >/dev/null 2>&1
    rm -rf "$p"
  done
  rm -rf "$CFG" "$CFGP"
  echo "cleanup: leftover projects for our dirs = $(fm_backend_paseo_cli project ls --json | jq --arg a "$P1" --arg b "$P2" '[.[]?|select((.path|startswith($a)) or (.path|startswith($b)))]|length')"
}
trap cleanup EXIT
echo "== S3 own workspace adopted (human-titled, same cwd) ahead of title lookup"
OWN=$(fm_backend_paseo_cli workspace create --isolation local --path "$P1" --title "Evidence Room" --json | jq -r '.workspaceId // .id')
echo "own workspace created: $OWN (title 'Evidence Room', cwd $P1)"
out=$(PASEO_WORKSPACE_ID=$OWN fm_backend_paseo_create_task fm-test-ownws "$P1"); echo "create_task -> $out"
read -r T1 W1 <<<"$out"
[ "$W1" = "$OWN" ] && echo "PASS S3: task tab adopted PASEO_WORKSPACE_ID workspace" || echo "FAIL S3"
fm_backend_paseo_cli workspace ls --json | jq -c --arg a "$P1" '[.[]?|select(.cwd==$a)|{workspaceId,name,cwd}]'
echo "== S4 PASEO_WORKSPACE_ID of ANOTHER project is ignored"
out=$(PASEO_WORKSPACE_ID=$OWN fm_backend_paseo_create_task fm-test-othws "$P2"); echo "create_task -> $out"
read -r T2 WS2 <<<"$out"
name=$(fm_backend_paseo_cli workspace ls --json | jq -r --arg id "$WS2" '.[]?|select(.workspaceId==$id)|"\(.name) \(.cwd)"')
echo "chosen workspace: $WS2 -> $name"
[ "$WS2" != "$OWN" ] && [ "${name%% *}" = firstmate ] && echo "PASS S4: new 'firstmate' workspace for other project" || echo "FAIL S4"
fm_backend_paseo_kill "$T1:$W1" >/dev/null 2>&1 || true
fm_backend_paseo_kill "$T2:$WS2" >/dev/null 2>&1 || true
