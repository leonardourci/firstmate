#!/usr/bin/env bash
# Live driver: backend selection / auto-detection, secondmate refusal vs
# fallback through the real bin/fm-spawn.sh, bootstrap's missing-CLI hint
# through the real bin/fm-bootstrap.sh, and bin/fm-test-run.sh family metadata.
set -u
WT=${WT:?}
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-sel.XXXXXX")
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home/config" "$SB/home/state" "$SB/home/data" "$SB/cfg-paseo" "$SB/cfg-empty" "$SB/projects"
printf 'paseo\n' >"$SB/cfg-paseo/backend"
export FM_GATE_REFUSE_BYPASS=1
PASS=0 FAILN=0
ok() { PASS=$((PASS + 1)); printf 'PASS - %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL - %s\n' "$1"; }

# name <label> <expected> <kind> <env assignments...>: resolve fm_backend_name
# in a scrubbed env with the given markers; print the result and stderr notice.
name() {
  local label=$1 want=$2 kind=$3 got err
  shift 3
  got=$(env -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u PASEO_AGENT_ID -u __CFBundleIdentifier \
    FM_HOME="$SB/home" FM_CONFIG_OVERRIDE="$SB/cfg-empty" "$@" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_name "$1"' "$WT" "$kind" 2>"$SB/err")
  err=$(cat "$SB/err")
  printf '  %-58s -> %-6s %s\n' "$label" "$got" "${err:+[stderr] $err}"
  [ "$got" = "$want" ] && ok "$label resolves $want" || bad "$label resolved '$got', wanted $want"
  LAST_ERR=$err
}

echo "=== S11 backend selection and auto-detection (fm_backend_name) ==="
name "no markers, no config" tmux ""
[ -z "$LAST_ERR" ] && ok "default tmux prints no notice" || bad "default tmux printed a notice"
name "FM_BACKEND=paseo" paseo "" FM_BACKEND=paseo
name "config/backend=paseo" paseo "" FM_CONFIG_OVERRIDE="$SB/cfg-paseo"
name "PASEO_AGENT_ID set (auto-detect)" paseo "" PASEO_AGENT_ID=agent-123
case "$LAST_ERR" in *"auto-detected paseo runtime (PASEO_AGENT_ID)"*EXPERIMENTAL*) ok "PASEO_AGENT_ID auto-detect prints the EXPERIMENTAL notice" ;; *) bad "missing EXPERIMENTAL notice" ;; esac
name "__CFBundleIdentifier=sh.paseo.desktop only (fallback)" paseo "" __CFBundleIdentifier=sh.paseo.desktop
case "$LAST_ERR" in *"FALLBACK signal __CFBundleIdentifier=sh.paseo.desktop"*EXPERIMENTAL*) ok "bundle-id fallback names the fallback signal" ;; *) bad "fallback notice wrong" ;; esac
name "TMUX + PASEO_AGENT_ID (inner multiplexer wins)" tmux "" TMUX=/tmp/fake,1,0 PASEO_AGENT_ID=agent-123
name "HERDR_ENV=1 + PASEO_AGENT_ID" herdr "" HERDR_ENV=1 PASEO_AGENT_ID=agent-123
name "auto-detected paseo, kind=secondmate" tmux secondmate PASEO_AGENT_ID=agent-123
name "explicit FM_BACKEND=paseo, kind=secondmate" paseo secondmate FM_BACKEND=paseo
name "config/backend=paseo, kind=secondmate" paseo secondmate FM_CONFIG_OVERRIDE="$SB/cfg-paseo"

echo
echo "=== S12 real bin/fm-spawn.sh --secondmate: explicit paseo refused, auto-detected paseo falls back ==="
spawn_sm() { # <config-dir> <FM_BACKEND> [args...]
  local cfg=$1 be=$2
  shift 2
  env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PASEO_AGENT_ID=agent-123 FM_BACKEND="$be" \
    FM_HOME="$SB/home" FM_STATE_OVERRIDE="$SB/home/state" FM_DATA_OVERRIDE="$SB/home/data" \
    FM_CONFIG_OVERRIDE="$cfg" FM_PROJECTS_OVERRIDE="$SB/projects" \
    "$WT/bin/fm-spawn.sh" sm-paseo-live --secondmate "$@" 2>&1
}
for c in "--backend paseo|$SB/cfg-empty||--backend paseo" "FM_BACKEND=paseo|$SB/cfg-empty|paseo|" "config/backend=paseo|$SB/cfg-paseo||"; do
  IFS='|' read -r label cfg be extra <<<"$c"
  # shellcheck disable=SC2086
  out=$(spawn_sm "$cfg" "$be" $extra); rc=$?
  printf '  [%s] rc=%s: %s\n' "$label" "$rc" "$(printf '%s' "$out" | grep -m1 -E 'error|REFUSED|NOTICE' || printf '%s' "$out" | tail -n1)"
  case "$out" in *"backend=paseo does not support --secondmate"*) [ "$rc" != 0 ] && ok "$label --secondmate refused" || bad "$label refused but rc=0" ;; *) bad "$label --secondmate not refused" ;; esac
done
out=$(spawn_sm "$SB/cfg-empty" ""); rc=$?
printf '  [auto-detected PASEO_AGENT_ID] rc=%s:\n%s\n' "$rc" "$(printf '%s' "$out" | head -n 4 | sed 's/^/    /')"
case "$out" in *"does not support --secondmate"*) bad "auto-detected paseo refused --secondmate" ;; *) ok "auto-detected paseo does not refuse --secondmate (continues past backend selection on tmux)" ;; esac
case "$out" in *"auto-detected paseo runtime"*) bad "secondmate spawn announced paseo" ;; *) ok "no paseo notice for the tmux-fallback secondmate spawn" ;; esac

echo
echo "=== S13 real bin/fm-bootstrap.sh with backend=paseo and the paseo CLI absent ==="
BS=$SB/bs; mkdir -p "$BS/home/config"
printf 'paseo\n' >"$BS/home/config/backend"; printf 'manual\n' >"$BS/home/config/backlog-backend"
out=$(env -u TMUX -u PASEO_AGENT_ID PATH=/usr/bin:/bin:/usr/sbin:/sbin FM_HOME="$BS/home" FM_ROOT_OVERRIDE="$BS/home" \
  FM_BACKEND_PASEO_BUNDLE_BIN="$BS/no-paseo" "$WT/bin/fm-bootstrap.sh" 2>&1)
printf '%s\n' "$out" | grep -E 'MISSING|BACKEND' | sed 's/^/    /'
case "$out" in *"MISSING_MANUAL: paseo (instructions: https://paseo.sh)"*) ok "bootstrap reports MISSING_MANUAL for paseo with the https://paseo.sh hint" ;; *) bad "bootstrap paseo hint missing" ;; esac
case "$out" in *"MISSING: paseo (install: )"*) bad "empty install hint printed" ;; *) ok "no empty 'install: ' hint" ;; esac
case "$out" in *"MISSING: tmux"*) bad "bootstrap demanded tmux for backend=paseo" ;; *) ok "bootstrap does not demand tmux for backend=paseo" ;; esac
out=$(env -u TMUX -u PASEO_AGENT_ID FM_HOME="$BS/home" FM_ROOT_OVERRIDE="$BS/home" "$WT/bin/fm-bootstrap.sh" 2>&1)
case "$out" in *"MISSING_MANUAL: paseo"*|*"MISSING: paseo"*) bad "bootstrap flagged paseo although it is installed" ;; *) ok "with the real paseo CLI on PATH bootstrap reports no missing paseo" ;; esac

echo
echo "=== S14 bin/fm-test-run.sh knows the paseo family ==="
"$WT/bin/fm-test-run.sh" --list-families | grep -qx paseo && ok "--list-families lists paseo" || bad "--list-families lacks paseo"
"$WT/bin/fm-test-run.sh" --list --family paseo 2>&1 | sed 's/^/    /'

printf '\nRESULT: %s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" = 0 ]
