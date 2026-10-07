#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh, real `claude auth status` (installed Claude
# Code), real `quota-axi` (installed). Only tmux/treehouse are faked (no real
# pane). Login roots are synthetic: signed in via apiKeyHelper (no real account
# touched). Each root's quota comes from real quota-axi answering from a
# QUOTA_AXI_SNAPSHOT fixture chosen per CLAUDE_CONFIG_DIR by a 3-line shim.
# usage: live-drive.sh <worktree> <room-snapshot> <spent-snapshot>
set -u
WT_ROOT=$1 ROOM=$2 SPENT=$3
. "$WT_ROOT/tests/fixtures.sh"
REAL_QA=$(command -v quota-axi)
TMP_ROOT=$(mktemp -d)
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR

new_case() { # <name> <ent-quota room|spent|signedout> <per-quota room|spent> [nofile]
  CASE="$TMP_ROOT/$1"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  # quota-axi shim: pick the fixture for the selected login, then exec the REAL quota-axi
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$CASE/quota-reads'
QUOTA_AXI_SNAPSHOT=\$(cat "\${CLAUDE_CONFIG_DIR:-/nonexistent}/snapshot-path" 2>/dev/null) exec '$REAL_QA' "\$@"
SH
  chmod +x "$FAKEBIN/quota-axi"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1" >/dev/null 2>&1
  mkdir -p "$HOME_DIR/user-home" "$CASE/enterprise" "$CASE/personal"
  for r in enterprise:$2 personal:$3; do
    d="$CASE/${r%%:*}"; q=${r#*:}
    [ "$q" = signedout ] && continue
    printf '{"apiKeyHelper":"echo sk-ant-fm-live-synthetic"}\n' > "$d/settings.json"
    [ "$q" = spent ] && echo "$SPENT" > "$d/snapshot-path" || echo "$ROOM" > "$d/snapshot-path"
  done
  [ "${4:-}" = nofile ] || printf '%s\n%s\n' "$CASE/enterprise" "$CASE/personal" > "$HOME_DIR/config/claude-account"
  : > "$CASE/launch.log"; : > "$CASE/quota-reads"
}

spawn() { # <id>
  fm_test_spawn_brief "$HOME_DIR" "$1"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$1" "$PROJ" \
    --mode no-mistakes --yolo off --model sonnet
}

report() { # <title> <id> <rc> <out>
  echo "=================================================================="
  echo "SCENARIO: $1"
  [ -f "$CASE/home/config/claude-account" ] && { echo "--- config/claude-account:"; sed "s|$TMP_ROOT|<tmp>|" "$CASE/home/config/claude-account"; } || echo "--- config/claude-account: (absent)"
  echo "--- fm-spawn.sh exit: $3"
  echo "--- fm-spawn.sh output (filtered):"
  printf '%s\n' "$4" | grep -E 'error|account=|spawned' | sed "s|$TMP_ROOT|<tmp>|g" | cut -c1-400
  echo "--- real quota-axi reads under logins: $(sed "s|$TMP_ROOT|<tmp>|" "$CASE/quota-reads" | tr '\n' ' ')"
  if [ -f "$HOME_DIR/state/$2.meta" ]; then
    echo "--- task record account=: $(grep '^account=' "$HOME_DIR/state/$2.meta" | sed "s|$TMP_ROOT|<tmp>|" || echo '(none)')"
  else echo "--- task record: (none published)"; fi
  if [ -s "$CASE/launch.log" ]; then
    echo "--- launch command CLAUDE_CONFIG_DIR: $(grep -o "CLAUDE_CONFIG_DIR=[^ ]*" "$CASE/launch.log" | head -1 | sed "s|$TMP_ROOT|<tmp>|" || echo '(not set: ambient login)')"
  else echo "--- launch command: (no worker launched)"; fi
}

new_case personal-home room room nofile; out=$(spawn t-personal); rc=$?
report "personal home (no config/claude-account): unchanged launch, no quota walk" t-personal $rc "$out"

new_case ent-room room room; out=$(spawn t-ent); rc=$?
report "work home, enterprise has room -> enterprise login" t-ent $rc "$out"

new_case ent-spent spent room; out=$(spawn t-fallback); rc=$?
report "work home, enterprise out of usage -> personal fallback" t-fallback $rc "$out"

new_case all-spent spent spent; out=$(spawn t-allspent); rc=$?
report "work home, enterprise AND personal out of usage -> blocked" t-allspent $rc "$out"

new_case ent-signedout signedout room; out=$(spawn t-signedout); rc=$?
report "work home, enterprise login not signed in -> refused (not silently skipped)" t-signedout $rc "$out"

rm -rf "$TMP_ROOT" 2>/dev/null; chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT" 2>/dev/null
