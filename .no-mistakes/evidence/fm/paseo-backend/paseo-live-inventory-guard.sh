#!/usr/bin/env bash
# Live check against the real Paseo daemon: inject failures into only the
# inventory reads (workspace ls / terminal ls) via a PATH shim that proxies
# every other call to the real paseo CLI; assert create_task refuses and
# creates nothing. Then prove capture of a quiet terminal is non-empty.
set -u
ROOT=$1
REAL=$(command -v paseo)
SHIM=$(mktemp -d); PROJ=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-guard.XXXXXX")" && pwd)
cat >"$SHIM/paseo" <<SH
#!/usr/bin/env bash
case "\${FAULT:-} \$1 \$2" in
  "ws-fail workspace ls") echo "daemon hiccup" >&2; exit 1 ;;
  "ws-garbage workspace ls") echo "Electron warning: not json"; exit 0 ;;
  "term-fail terminal ls") echo "daemon hiccup" >&2; exit 1 ;;
esac
exec "$REAL" "\$@"
SH
chmod +x "$SHIM/paseo"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source paseo
counts() { printf 'workspaces=%s terminals=%s projects=%s' \
  "$("$REAL" workspace ls --json 2>/dev/null | jq length)" \
  "$("$REAL" terminal ls --all --json 2>/dev/null | jq length)" \
  "$("$REAL" project ls --json 2>/dev/null | jq length)"; }
rc_all=0
WS=""
cleanup() {
  [ -z "$WS" ] || "$REAL" workspace archive "$WS" >/dev/null 2>&1
  prj=$("$REAL" project ls --json 2>/dev/null | jq -r --arg p "$PROJ" '.[]?|select(.path==$p)|.projectId' | head -1)
  [ -z "$prj" ] || "$REAL" project delete "$prj" >/dev/null 2>&1
  rm -rf "$SHIM" "$PROJ"
}
trap cleanup EXIT
for f in ws-fail ws-garbage; do
  before=$(counts)
  out=$(FAULT=$f PATH="$SHIM:$PATH" fm_backend_paseo_create_task fm-test-guard-$f "$PROJ" 2>&1); rc=$?
  after=$(counts)
  echo "== FAULT=$f: rc=$rc"; echo "   stderr/out: $out"; echo "   before: $before"; echo "   after:  $after"
  { [ $rc -ne 0 ] && [ "$before" = "$after" ]; } && echo "   PASS refused, nothing created" || { echo "   FAIL"; rc_all=1; }
done
# terminal-ls fault needs the shared workspace to exist first (normal spawn),
# so the only thing left to create is the duplicate-checked terminal.
ids=$(PATH="$SHIM:$PATH" fm_backend_paseo_create_task fm-test-guard-seed "$PROJ") || { echo "seed spawn FAIL"; exit 1; }
read -r SEED WS <<<"$ids"; echo "== seed task created: terminal=$SEED workspace=$WS"
before=$(counts)
out=$(FAULT=term-fail PATH="$SHIM:$PATH" fm_backend_paseo_create_task fm-test-guard-term "$PROJ" 2>&1); rc=$?
after=$(counts)
echo "== FAULT=term-fail: rc=$rc"; echo "   stderr/out: $out"; echo "   before: $before"; echo "   after:  $after"
{ [ $rc -ne 0 ] && [ "$before" = "$after" ]; } && echo "   PASS refused, nothing created" || { echo "   FAIL"; rc_all=1; }
# control: same call without fault succeeds, in the same workspace
ids=$(PATH="$SHIM:$PATH" fm_backend_paseo_create_task fm-test-guard-term "$PROJ") && read -r T2 W2 <<<"$ids"
[ "${W2:-}" = "$WS" ] && echo "== control (no fault): created terminal=$T2 in same workspace $W2 PASS" || { echo "control FAIL"; rc_all=1; }
# quiet-terminal capture: fresh idle prompt must not capture as empty
sleep 1.5
cap=$(fm_backend_paseo_capture "$SEED:$WS" 20)
echo "== quiet-terminal capture (seed tab, nothing typed), last 20 lines:"; printf '%s\n' "$cap" | sed 's/^/   | /'
[ -n "$(printf '%s' "$cap" | tr -d '[:space:]')" ] && echo "   PASS non-empty" || { echo "   FAIL empty capture"; rc_all=1; }
echo "RESULT rc=$rc_all"; exit $rc_all
