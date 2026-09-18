#!/usr/bin/env bash
# Runs INSIDE a real Paseo 0.8.0 terminal tab (created by drive-live-paseo.sh),
# so every PASEO_* marker below is the one Paseo itself exported to the tab.
# Usage: inside-paseo-tab.sh <firstmate-root> <project P> <other project Q> <firstmate-titled wks for P>
set -u
ROOT=$1 P=$2 Q=$3 WKS_TITLED=$4
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-live-sb.XXXXXX")
mkdir -p "$SB/state" "$SB/data" "$SB/config" "$SB/config-paseo" "$SB/projects"
printf 'paseo\n' >"$SB/config-paseo/backend"
unset TMUX HERDR_ENV CMUX_WORKSPACE_ID FM_BACKEND

echo "== markers Paseo exported into this tab =="
env | grep -E '^(PASEO_|__CFBundleIdentifier=)' | sed -E 's/^(PASEO_ACTIVITY_TOKEN=).*/\1<redacted>/' | sort
echo "PASEO_AGENT_ID is ${PASEO_AGENT_ID+set}${PASEO_AGENT_ID-UNSET}"

name_in() { # <config-dir> -> fm_backend_name result + stderr
  bash -c '. "$0/bin/fm-backend.sh"; out=$(FM_BACKEND_CONFIG_DIR="$1" fm_backend_name 2>"$2"); printf "fm_backend_name=[%s] stderr=[%s]\n" "$out" "$(cat "$2")"' "$ROOT" "$1" "$SB/name.err"
}

echo
echo "== S1 detection ignores real Paseo tab markers =="
bash -c '. "$0/bin/fm-backend.sh"; out=$(fm_backend_detect); rc=$?; printf "fm_backend_detect rc=%s out=[%s]\n" "$rc" "$out"' "$ROOT"
name_in "$SB/config"
echo "-- same tab + agent marker (PASEO_AGENT_ID=fm-test-agent, as a Paseo agent exports) --"
PASEO_AGENT_ID=fm-test-agent bash -c '. "$0/bin/fm-backend.sh"; out=$(fm_backend_detect); rc=$?; printf "fm_backend_detect rc=%s out=[%s]\n" "$rc" "$out"' "$ROOT"
PASEO_AGENT_ID=fm-test-agent name_in "$SB/config"
echo "-- same tab + TMUX set (simulated: tmux not installed on this host) --"
TMUX='/tmp/fake-tmux,1,0' bash -c '. "$0/bin/fm-backend.sh"; printf "fm_backend_detect=[%s]\n" "$(fm_backend_detect)"' "$ROOT"

echo
echo "== S2 explicit selection still selects paseo =="
FM_BACKEND=paseo bash -c '. "$0/bin/fm-backend.sh"; printf "FM_BACKEND=paseo -> [%s]\n" "$(FM_BACKEND_CONFIG_DIR="$1" fm_backend_name)"' "$ROOT" "$SB/config"
bash -c '. "$0/bin/fm-backend.sh"; printf "config/backend=paseo -> [%s]\n" "$(FM_BACKEND= FM_BACKEND_CONFIG_DIR="$1" fm_backend_name)"' "$ROOT" "$SB/config-paseo"

spawn_sm() { # <config-dir> <FM_BACKEND> [args...]
  local cfg=$1 be=$2; shift 2
  FM_STATE_OVERRIDE="$SB/state" FM_DATA_OVERRIDE="$SB/data" FM_CONFIG_OVERRIDE="$cfg" \
    FM_PROJECTS_OVERRIDE="$SB/projects" FM_BACKEND="$be" \
    "$ROOT/bin/fm-spawn.sh" sm-paseo-live --harness claude --secondmate "$@" 2>&1 | head -3
  echo "   exit=${PIPESTATUS[0]}"
}
echo
echo "== S3 fm-spawn.sh --secondmate inside the real Paseo tab =="
echo "-- unconfigured home (nothing selects paseo) --"
spawn_sm "$SB/config" ''
echo "-- unconfigured home + PASEO_AGENT_ID --"
PASEO_AGENT_ID=fm-test-agent spawn_sm "$SB/config" ''
echo "-- --backend paseo --"
spawn_sm "$SB/config" '' --backend paseo
echo "-- FM_BACKEND=paseo --"
spawn_sm "$SB/config" paseo
echo "-- config/backend=paseo --"
spawn_sm "$SB/config-paseo" ''

create() { # <label> <cwd> [PASEO_WORKSPACE_ID override]
  if [ $# -ge 3 ]; then
    PASEO_WORKSPACE_ID=$3 FM_BACKEND=paseo bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source paseo; fm_backend_paseo_create_task "$1" "$2"' "$ROOT" "$1" "$2"
  else
    FM_BACKEND=paseo bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source paseo; fm_backend_paseo_create_task "$1" "$2"' "$ROOT" "$1" "$2"
  fi
}
echo
echo "== S4 explicit paseo adopts the tab's own workspace (PASEO_WORKSPACE_ID=$PASEO_WORKSPACE_ID) ahead of the 'firstmate'-titled $WKS_TITLED =="
out=$(create fm-test-own "$P"); echo "create_task -> [$out]"
echo "CREATED_OWN=$out"
echo
echo "== S5 own workspace belongs to P; a task for other project Q must NOT land in it =="
out=$(create fm-test-other "$Q"); echo "create_task -> [$out]"
echo "CREATED_OTHER=$out"
echo
echo "== S6 stale PASEO_WORKSPACE_ID falls back to the 'firstmate' title lookup =="
out=$(create fm-test-stale "$P" wks_doesnotexist0000); echo "create_task -> [$out]"
echo "CREATED_STALE=$out"

rm -rf "$SB"
echo "DRIVER-DONE after ${SECONDS}s"
