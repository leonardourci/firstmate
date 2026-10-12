#!/usr/bin/env bash
# Public-interface regressions for copy-only recovery and failed allocation.
# Real Git worktrees, isolated homes, and a stateful Paseo/Treehouse fixture.
set -eu
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity 'Firstmate Tests' tests@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-treehouse-recovery)
REAL_LSOF=$(command -v lsof || true)
live_service_pid=
trap '[ -z "$live_service_pid" ] || { kill "$live_service_pid" 2>/dev/null || true; wait "$live_service_pid" 2>/dev/null || true; }; fm_test_cleanup' EXIT

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/pool/1/project"
  FB="$CASE/fakebin"
  mkdir -p "$FB" "$CASE/pool"
  fm_test_spawn_home "$HOME_DIR" codex
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  fm_git_worktree "$PROJ" "$WT" fixture-work
  git -C "$PROJ" fetch -q origin
  holder=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_task_lease_holder dead "$2" s1.2.3' bash "$ROOT" "$HOME_DIR")
  jq -n --arg path "$WT" --arg holder "$holder" '{worktrees:[{name:"1",path:$path,leased:true,lease_id:"fixture-old",lease_holder:$holder}]}' > "$CASE/pool/treehouse-state.json"
  printf '[]\n' > "$CASE/inventory"
  printf '%s\n' "$PROJ" > "$CASE/cwd"
  fm_write_meta "$HOME_DIR/state/dead.meta" "kind=ship" "backend=paseo" \
    "window=old:wks_test" "paseo_terminal_id=old" "paseo_workspace_id=wks_test" \
    "endpoint_task_id=dead" "project=$PROJ" "worktree=$WT" "spawn_gen=s1.2.3" \
    "mode=no-mistakes" "yolo=off"
  printf 'task=dead\nhome=%s\nspawn_gen=s1.2.3\nnative_owner=lease:fixture-old\n' "$HOME_DIR" > "$CASE/pool/1/.fm-slot-owner"
  printf 'working [at=1]: evidence\n' > "$HOME_DIR/state/dead.status"
  printf '# In flight\n- dead: preserve this task\n' > "$HOME_DIR/data/backlog.md"
  cp "$HOME_DIR/data/backlog.md" "$CASE/backlog.before"
  cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  -v) echo 0.10.3 ;;
  'status --json') echo '{"localDaemon":"running","connectedDaemon":"reachable"}' ;;
  'workspace ls --json') printf '[{"workspaceId":"wks_test","name":"firstmate","cwd":"%s"}]\n' "$TEST_PROJECT" ;;
  'terminal ls --all --json')
    [ ! -f "$TEST_CASE/inventory-error" ] || exit 1
    cat "$TEST_CASE/inventory" ;;
  'terminal create '*)
    name=''
    while [ "$#" -gt 0 ]; do [ "$1" != --name ] || name=$2; shift; done
    jq -n --arg name "$name" '[{id:"new",workspaceId:"wks_test",name:$name}]' > "$TEST_CASE/inventory"
    echo '{"id":"new"}' ;;
  'terminal kill '*)
    [ ! -f "$TEST_CASE/kill-error" ] || exit 1
    echo '[]' > "$TEST_CASE/inventory"
    echo killed >> "$TEST_CASE/kills" ;;
  'terminal send-keys '*'-l -- '*)
    for last; do :; done
    printf '%s' "$last" > "$TEST_CASE/input" ;;
  'terminal send-keys '*' Enter')
    line=$(cat "$TEST_CASE/input" 2>/dev/null || true)
    case "$line" in
      *'treehouse get'*)
        (cd "$TEST_PROJECT"; bash -c "$line") > "$TEST_CASE/capture" 2>&1
        [ ! -f "$TEST_CASE/freed" ] || printf '%s\n' "$TEST_WORKTREE" > "$TEST_CASE/cwd" ;;
      *'__FM_PASEO_CWD_BEGIN__'*)
        (cd "$(cat "$TEST_CASE/cwd")"; bash -c "$line") > "$TEST_CASE/capture" ;;
    esac ;;
  'terminal capture '*)
    jq -n --rawfile text "$TEST_CASE/capture" '{terminalId:"new",lines:($text|split("\n")),totalLines:10}' ;;
  *) ;;
esac
SH
  cat > "$FB/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  status) jq -n --arg path "${TEST_POOL_PATH:-$TEST_WORKTREE}" '[{path:$path,status:"available"}]' ;;
  return)
    printf 'return %s\n' "$*" >> "$TEST_CASE/returns"
    [ ! -f "$TEST_CASE/return-error" ] || exit 1
    expected=''
    while [ "$#" -gt 0 ]; do [ "$1" != --if-lease-id ] || expected=$2; shift; done
    if [ -f "$TEST_CASE/lease-race" ]; then
      jq '.worktrees[0].lease_id="successor"' "$TEST_CASE/pool/treehouse-state.json" > "$TEST_CASE/native"
      mv "$TEST_CASE/native" "$TEST_CASE/pool/treehouse-state.json"
    fi
    actual=$(jq -r '.worktrees[0].lease_id // ""' "$TEST_CASE/pool/treehouse-state.json")
    [ -z "$expected" ] || [ "$expected" = "$actual" ] || exit 1
    jq '.worktrees[0] |= del(.leased,.lease_id,.lease_holder)' "$TEST_CASE/pool/treehouse-state.json" > "$TEST_CASE/native"
    mv "$TEST_CASE/native" "$TEST_CASE/pool/treehouse-state.json"
    touch "$TEST_CASE/freed" ;;
  get)
    if [ -f "$TEST_CASE/freed" ]; then
      [ ! -f "$TEST_CASE/success-noise" ] || echo 'all 1 worktrees are in use or dirty (max_trees = 1).' >&2
      holder=''
      while [ "$#" -gt 0 ]; do [ "$1" != --lease-holder ] || holder=$2; shift; done
      jq --arg holder "$holder" '.worktrees[0] |= . + {leased:true,lease_id:"fixture-new",lease_holder:$holder}' "$TEST_CASE/pool/treehouse-state.json" > "$TEST_CASE/native"
      mv "$TEST_CASE/native" "$TEST_CASE/pool/treehouse-state.json"
      printf '%s\n' "$TEST_WORKTREE"
      exit 0
    fi
    error="all 1 worktrees are in use or dirty (max_trees = 1). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml"
    if [ -f "$TEST_CASE/wrapped-error" ]; then printf '%s\n' "$error" | fold -w 40; else printf '%s\n' "$error"; fi
    exit 1 ;;
  *) ;;
esac
SH
  cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'no-mistakes version v1.75.2' ;;
  axi) cat "${TEST_CASE:?}/pipeline" ;;
  *) ;;
esac
SH
  cat > "$FB/lsof" <<'SH'
#!/usr/bin/env bash
if [ -f "$TEST_CASE/lsof-error" ]; then exit 1; fi
if [ -f "$TEST_CASE/live-process" ]; then printf 'p123\nfcwd\nn%s\n' "$TEST_WORKTREE"; fi
if [ -f "$TEST_CASE/open-file-process" ]; then printf 'p123\nf7\nn%s/file\n' "$TEST_WORKTREE"; fi
SH
  printf 'count: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' > "$CASE/pipeline"
  chmod +x "$FB"/*
  export TEST_CASE="$CASE" TEST_PROJECT="$PROJ" TEST_WORKTREE="$WT"
}

run_return() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FB:$PATH" bash "$ROOT/bin/fm-teardown.sh" dead --return-copy
}

assert_retained() {
  [ ! -f "$CASE/returns" ] || fail "$1 returned unsafe work"
  assert_grep "worktree=$WT" "$HOME_DIR/state/dead.meta" "$1 changed live copy identity"
  cmp "$CASE/backlog.before" "$HOME_DIR/data/backlog.md" || fail "$1 changed backlog"
}

for scenario in dirty untracked unpushed live ambiguous malformed claim home generation legacy native-generation native-lease native-live process open-file lsof pipeline pipeline-unknown; do
  make_case "$scenario"
  case "$scenario" in
    dirty) echo changed >> "$WT/README.md" ;;
    untracked) echo preserve > "$WT/secret-note" ;;
    unpushed) echo local > "$WT/local"; git -C "$WT" add local; git -C "$WT" commit -qm local ;;
    live) jq -n '[{id:"old",workspaceId:"wks_test",name:"other"}]' > "$CASE/inventory" ;;
    ambiguous) touch "$CASE/inventory-error" ;;
    malformed) echo '[{"id":"old"}]' > "$CASE/inventory" ;;
    claim) sed 's/task=dead/task=another/' "$CASE/pool/1/.fm-slot-owner" > "$CASE/claim"; mv "$CASE/claim" "$CASE/pool/1/.fm-slot-owner" ;;
    home) sed "s@home=.*@home=$CASE@" "$CASE/pool/1/.fm-slot-owner" > "$CASE/claim"; mv "$CASE/claim" "$CASE/pool/1/.fm-slot-owner" ;;
    generation) sed 's/spawn_gen=.*/spawn_gen=other/' "$CASE/pool/1/.fm-slot-owner" > "$CASE/claim"; mv "$CASE/claim" "$CASE/pool/1/.fm-slot-owner" ;;
    native-generation) jq '.worktrees[0].lease_id="other-owner"' "$CASE/pool/treehouse-state.json" > "$CASE/native"; mv "$CASE/native" "$CASE/pool/treehouse-state.json" ;;
    native-lease) jq '.worktrees[0].lease_holder="other-owner"' "$CASE/pool/treehouse-state.json" > "$CASE/native"; mv "$CASE/native" "$CASE/pool/treehouse-state.json" ;;
    native-live)
      jq --argjson pid "$$" '.worktrees[0] |= {name:.name,path:.path,owner_pid:$pid,owner_started_at:1}' "$CASE/pool/treehouse-state.json" > "$CASE/native"; mv "$CASE/native" "$CASE/pool/treehouse-state.json"
      sed "s/native_owner=.*/native_owner=process:$$:1/" "$CASE/pool/1/.fm-slot-owner" > "$CASE/claim"; mv "$CASE/claim" "$CASE/pool/1/.fm-slot-owner" ;;
    legacy) sed '/spawn_gen=/d' "$CASE/pool/1/.fm-slot-owner" > "$CASE/claim"; mv "$CASE/claim" "$CASE/pool/1/.fm-slot-owner" ;;
    process) touch "$CASE/live-process" ;;
    open-file) touch "$CASE/open-file-process" ;;
    lsof) touch "$CASE/lsof-error" ;;
    pipeline) printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  active,fixture-work,running,abc,\n' > "$CASE/pipeline" ;;
    pipeline-unknown) echo invalid > "$CASE/pipeline" ;;
  esac
  if run_return > "$CASE/output" 2>&1; then fail "$scenario recovery must refuse"; fi
  assert_retained "$scenario"
  pass "$scenario work retained through executable return interface"
done

make_case stale-native-teardown
jq '.worktrees[0].lease_id="successor"' "$CASE/pool/treehouse-state.json" > "$CASE/native"
mv "$CASE/native" "$CASE/pool/treehouse-state.json"
if FM_HOME="$HOME_DIR" FM_TEARDOWN_GUARD_DONE=1 PATH="$FB:$PATH" bash "$ROOT/bin/fm-teardown.sh" dead --force > "$CASE/output" 2>&1; then fail 'ordinary teardown accepted changed native allocation'; fi
assert_retained 'stale-native-teardown'
pass 'ordinary teardown refuses changed native allocation even with force'

make_case malformed-native-teardown
printf 'native_owner=lease:duplicate\n' >> "$CASE/pool/1/.fm-slot-owner"
if FM_HOME="$HOME_DIR" FM_TEARDOWN_GUARD_DONE=1 PATH="$FB:$PATH" bash "$ROOT/bin/fm-teardown.sh" dead --force > "$CASE/output" 2>&1; then fail 'ordinary teardown accepted ambiguous native claim'; fi
assert_retained 'malformed-native-teardown'
pass 'ordinary teardown refuses ambiguous native claims even with force'

make_case safe
run_return > "$CASE/output" 2>&1 || fail "safe return: $(cat "$CASE/output")"
grep -Fx 'worktree=' "$HOME_DIR/state/dead.meta" >/dev/null || fail 'live identity must be cleared'
assert_grep 'worktree_state=returned' "$HOME_DIR/state/dead.meta" 'success receipt missing'
assert_no_grep 'return.*--force' "$CASE/returns" 'automatic return must not force cleanup'
assert_grep "returned_worktree=$WT" "$HOME_DIR/state/dead.meta" 'history missing'
[ -f "$HOME_DIR/state/dead.status" ] || fail 'status record lost'
cmp "$CASE/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'return closed backlog'
run_return > "$CASE/repeat" 2>&1 || fail 'idempotent repeat failed'
[ "$(wc -l < "$CASE/returns" | tr -d ' ')" = 1 ] || fail 'repeat returned twice'
# A successor occupies the identical path. Old return and teardown must not
# inspect or reset it, even with dirty work present.
printf 'task=successor\nhome=%s\nspawn_gen=new\n' "$HOME_DIR" > "$CASE/pool/1/.fm-slot-owner"
echo successor > "$WT/untracked"
run_return >/dev/null || fail 'old receipt did not survive reuse'
[ -f "$WT/untracked" ] || fail 'old record touched successor'
state=$(FM_HOME="$HOME_DIR" PATH="$FB:$PATH" bash "$ROOT/bin/fm-crew-state.sh" dead)
assert_contains "$state" 'copy returned to pool' 'status reader followed historical path'
FM_HOME="$HOME_DIR" FM_TEARDOWN_GUARD_DONE=1 PATH="$FB:$PATH" bash "$ROOT/bin/fm-teardown.sh" dead > "$CASE/teardown" 2>&1 || fail "records-only teardown failed: $(cat "$CASE/teardown")"
[ -f "$WT/untracked" ] || fail 'records-only teardown touched successor'
[ "$(wc -l < "$CASE/returns" | tr -d ' ')" = 1 ] || fail 'records-only teardown returned successor'
pass 'safe return is idempotent; status and later teardown keep reused slot untouched'

make_case conditional-race
touch "$CASE/lease-race"
if run_return > "$CASE/output" 2>&1; then fail 'conditional return accepted successor allocation'; fi
assert_grep 'worktree_state=returning' "$HOME_DIR/state/dead.meta" 'conditional refusal lost journal'
[ "$(jq -r '.worktrees[0].lease_id' "$CASE/pool/treehouse-state.json")" = successor ] || fail 'conditional refusal changed successor lease'
[ ! -f "$CASE/freed" ] || fail 'conditional refusal returned successor'
cmp "$CASE/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'conditional refusal changed backlog'
pass 'allocator replacement at return is refused by exact lease comparison'

make_case partial
touch "$CASE/return-error"
if run_return > "$CASE/output" 2>&1; then fail 'partial return reported success'; fi
assert_grep 'worktree_state=returning' "$HOME_DIR/state/dead.meta" 'partial journal missing'
if run_return > "$CASE/repeat" 2>&1; then fail 'partial retry must refuse'; fi
[ "$(wc -l < "$CASE/returns" | tr -d ' ')" = 1 ] || fail 'partial retry touched slot'
pass 'partial return preserves journal and cannot return a reused slot'

# Exercise the allocation error and rollback through the full spawn executable.
make_case allocation
rm "$HOME_DIR/state/dead.meta"
fm_test_spawn_brief "$HOME_DIR" retry
before=$(date +%s)
if fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" retry "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/output"; then fail 'pool-full spawn must fail'; fi
assert_contains "$(cat "$CASE/output")" "all 1 worktrees are in use or dirty (max_trees = 1). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" 'allocator text lost'
[ $(( $(date +%s) - before )) -lt 30 ] || fail 'definite failure waited for generic 60s timeout'
[ "$(cat "$CASE/inventory")" = '[]' ] || fail 'created endpoint orphaned'
if fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" retry "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/retry"; then fail 'still-full retry must fail'; fi
assert_no_grep 'already exists' "$CASE/retry" 'orphan blocked same-task retry'
pass 'exact allocator error fails early, closes created endpoint, permits same-task retry'

make_case pool-full
touch "$CASE/wrapped-error"
fm_test_spawn_brief "$HOME_DIR" replacement
fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" replacement "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/output" || fail "reclaimed retry failed: $(cat "$CASE/output")"
assert_grep 'worktree_state=returned' "$HOME_DIR/state/dead.meta" 'dead record not retained'
assert_grep "worktree=$WT" "$HOME_DIR/state/replacement.meta" 'retry did not acquire freed matching slot'
cmp "$CASE/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'pool-full recovery closed backlog'
pass 'wrapped pool-full error reclaims only safe matching copy and retries successfully'

make_case proactive
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' PATH="$FB:$PATH" bash "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup > "$CASE/output" 2>&1 || fail "proactive reconciliation failed: $(cat "$CASE/output")"
assert_grep 'worktree_state=returned' "$HOME_DIR/state/dead.meta" 'inactive reconciliation did not return copy'
cmp "$CASE/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'proactive reconciliation closed backlog'
pass 'existing inactive reconciliation proactively returns dead copy without closing task'

make_case preserved-outcome
printf 'failed [at=1]: recorded failure\n' > "$HOME_DIR/state/dead.status"
touch -t 200001010000 "$HOME_DIR/state/dead.meta" "$HOME_DIR/state/dead.status"
cat > "$FB/observed-state" <<'SH'
#!/usr/bin/env bash
# The existing reader can observe the real historical outcome only while the
# live copy identity is present. Pin ordering, not the runtime classifier.
if grep -q '^worktree=$' "$FM_HOME/state/dead.meta"; then
  echo 'state: unknown source=none detail=copy returned'
else
  echo 'state: failed source=status-log detail=recorded failure'
fi
SH
chmod +x "$FB/observed-state"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_INACTIVE_CREW_STATE_BIN="$FB/observed-state" PATH="$FB:$PATH" bash "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup > "$CASE/output" 2>&1 || fail 'outcome reconciliation failed'
assert_grep 'worktree_state=returned' "$HOME_DIR/state/dead.meta" 'outcome case did not return copy'
count=0
for receipt in "$HOME_DIR/state/terminal-outcomes"/*.pending; do [ ! -f "$receipt" ] || count=$((count + 1)); done
[ "$count" = 1 ] || fail 'copy return suppressed existing outcome observation'
assert_grep 'recorded failure' "$HOME_DIR/state/dead.status" 'historical outcome lost'
pass 'existing outcome is recorded before copy identity is cleared'

make_case decisions
printf 'needs-decision [at=1] [key=review-call]: retained question\n' > "$HOME_DIR/state/dead.status"
cp "$HOME_DIR/state/dead.status" "$CASE/status.before"
run_return > "$CASE/output" 2>&1 || fail 'pending decision prevented safe copy-only return'
cmp "$CASE/status.before" "$HOME_DIR/state/dead.status" || fail 'copy return resolved pending decision'
state=$(FM_HOME="$HOME_DIR" PATH="$FB:$PATH" bash "$ROOT/bin/fm-crew-state.sh" dead)
assert_contains "$state" 'state: parked' 'returned receipt hid pending decision'
pass 'copy return preserves pending decisions verbatim and keeps them visible in status'

make_case other-pool
if TEST_POOL_PATH="$CASE/another-pool/1/project" FM_HOME="$HOME_DIR" PATH="$FB:$PATH" bash "$ROOT/bin/fm-treehouse-recover.sh" pool "$PROJ" > "$CASE/output" 2>&1; then fail 'another pool authorized a retry'; fi
assert_retained 'other-pool'
pass 'pool recovery cannot free a slot outside the actual matching pool'

make_case cleanup-failed
rm "$HOME_DIR/state/dead.meta"
touch "$CASE/kill-error"
fm_test_spawn_brief "$HOME_DIR" retained-endpoint
if fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" retained-endpoint "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/output"; then fail 'full pool must fail'; fi
assert_grep 'could not prove cleanup' "$CASE/output" 'cleanup failure hidden'
[ "$(cat "$CASE/inventory")" != '[]' ] || fail 'cleanup failure falsely erased endpoint'
[ ! -f "$CASE/kills" ] || fail 'failed kill reported success'
# The failed cleanup leaves a pre-existing endpoint. The next spawn must refuse
# it without another kill or any acquisition/return.
if fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" retained-endpoint "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/retry"; then fail 'pre-existing endpoint should refuse'; fi
assert_grep 'already exists' "$CASE/retry" 'pre-existing endpoint was adopted'
[ ! -f "$CASE/kills" ] || fail 'retry killed pre-existing endpoint'
pass 'cleanup failure is explicit and retry preserves a pre-existing endpoint'

if [ -n "$REAL_LSOF" ] && command -v python3 >/dev/null 2>&1; then
  make_case real-open-file
  rm "$FB/lsof"
  ln -s "$REAL_LSOF" "$FB/lsof"
  # This real service's cwd is outside the copy; only its open file proves use.
  python3 -c 'import sys,time; f=open(sys.argv[1]); open(sys.argv[2],"w").write("ready"); time.sleep(120)' "$WT/README.md" "$CASE/ready" &
  live_service_pid=$!
  for _ in $(seq 1 100); do [ ! -f "$CASE/ready" ] || break; sleep 0.1; done
  [ -f "$CASE/ready" ] || fail 'real file-holder did not become ready'
  if run_return > "$CASE/output" 2>&1; then fail 'real service open file allowed return'; fi
  assert_grep 'has live processes or open files' "$CASE/output" 'real lsof did not positively identify open-file service'
  assert_retained 'real-open-file'
  kill "$live_service_pid"
  wait "$live_service_pid" 2>/dev/null || true
  live_service_pid=
  pass 'real service with cwd outside copy and an open file inside it prevents return'
else
  echo 'skip: real open-file process regression requires lsof and python3'
fi

make_case success-noise
rm "$HOME_DIR/state/dead.meta"
touch "$CASE/freed" "$CASE/success-noise"
fm_test_spawn_brief "$HOME_DIR" successful-command
fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FB" successful-command "$PROJ" --backend paseo --mode no-mistakes --yolo off > "$CASE/output" || fail 'error-like output from a successful command was treated as allocation failure'
[ ! -f "$CASE/returns" ] || fail 'successful command noise triggered pool recovery'
[ ! -f "$CASE/kills" ] || fail 'successful acquisition endpoint was closed'
pass 'error-like output without a completed nonzero command cannot trigger recovery or cleanup'
