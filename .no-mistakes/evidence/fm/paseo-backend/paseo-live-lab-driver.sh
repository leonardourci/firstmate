#!/usr/bin/env bash
# Live drive of the real firstmate entrypoints, backend=paseo, in a marked lab home.
# The external Paseo CLI is a disposable stateful stand-in (never the real daemon).
set -u
ROOT=~/.no-mistakes/worktrees/6e55bfafc110/01M526A9F94FGQYH94TE5ASQWP
FB=/tmp/fm-paseo-live/bin
cd "$ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/user-home"
export FM_FAKE_PASEO_STATE="$LAB/.paseo-fake"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID PASEO_TERMINAL_ID FM_BACKEND
id=paseo-ext-r1
PROJ="$LAB/projects/project"; ORIGIN="$LAB/origin.git"; POOL="$LAB/pool"
printf 'codex\n' > "$LAB/config/crew-harness"
printf '%s\n' 'Run `review-tool upload --draft`.' > "$LAB/config/external-review.md"
printf -- '- project [direct-PR forge=external] - fixture (added 2026-01-01)\n' > "$LAB/data/projects.md"
touch "$LAB/state/.last-watcher-beat"
git init --quiet -b main "$PROJ"; printf 'base\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=T -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$ORIGIN"
git -C "$PROJ" remote add origin "file://$ORIGIN"; git -C "$PROJ" fetch --quiet origin
git -C "$PROJ" worktree add --quiet --detach "$POOL" "$(git -C "$PROJ" rev-parse HEAD)"
printf 'backup\n' > "$LAB/config/external-review-backup"
git init --quiet --bare "$LAB/backup.git"; git -C "$PROJ" remote add backup "file://$LAB/backup.git"
mkdir -p "$LAB/data/$id"
cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Ship a change through the review tool on the paseo backend.

## Firstmate spec
Exercise the external review spawn path on paseo.

# Definition of done
Delivery contract: mode=direct-PR forge=external
Ship branch: fm/$id
EOF
run() { FM_HOME="$LAB" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR= FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL" TMUX="fake,1,0" PATH="$FB:$PATH" "$@" 2>&1; echo "### exit=$?"; }
echo "========== S1: spawn ship task, --backend paseo, forge=external project"
echo "\$ fm-spawn.sh $id <project> --backend paseo --mode direct-PR --yolo off"
run bin/fm-spawn.sh "$id" "$PROJ" --backend paseo --mode direct-PR --yolo off | tail -8
echo "--- state/$id.meta:"; cat "$LAB/state/$id.meta"
echo "--- push guard hook: $(ls "$LAB/state/$id.git-hooks/" 2>&1 | tr '\n' ' ')"
echo "--- fake paseo workspaces: $(jq -c . "$FM_FAKE_PASEO_STATE/ws.json")"
echo "--- fake paseo terminals: $(jq -c . "$FM_FAKE_PASEO_STATE/term.json")"
echo
echo "========== S2: peek + send route through the paseo adapter"
echo "\$ fm-peek.sh $id"; run bin/fm-peek.sh "$id"
: > "$FM_FAKE_PASEO_STATE/sends.log"
echo "\$ fm-send.sh $id 'hello from captain'"; run bin/fm-send.sh "$id" 'hello from captain'
echo "--- paseo send-keys received:"; cat "$FM_FAKE_PASEO_STATE/sends.log"
echo
echo "========== S3: relaunch on paseo refuses, record untouched"
before=$(shasum < "$LAB/state/$id.meta")
echo "\$ fm-spawn.sh $id --relaunch"; run bin/fm-spawn.sh "$id" --relaunch
echo "\$ fm-control.sh $id relaunch"; run bin/fm-control.sh "$id" relaunch
after=$(shasum < "$LAB/state/$id.meta")
[ "$before" = "$after" ] && echo "--- meta byte-identical after refused relaunches (forge + paseo keys intact)" || echo "--- META CHANGED"
echo
echo "========== S4: --secondmate --backend paseo refuses"
printf claude > "$LAB/config/secondmate-harness"
echo "\$ fm-spawn.sh sm-x --secondmate --backend paseo"; run bin/fm-spawn.sh sm-x --secondmate --backend paseo
echo "--- secondmate meta exists? $( [ -e "$LAB/state/sm-x.meta" ] && echo yes || echo no )"
echo
echo "========== S5: inherited PASEO_* markers never auto-select paseo"
id2=autodetect-r1
mkdir -p "$LAB/data/$id2"; printf '# Task\n## Captain'"'"'s intent\nscout\n\n## Firstmate spec\nscout\n' > "$LAB/data/$id2/brief.md"
calls_before=$(wc -l < "$FM_FAKE_PASEO_STATE/calls.log")
echo "\$ PASEO_WORKSPACE_ID=wks_inherited PASEO_AGENT_ID=agent1 fm-spawn.sh $id2 <project> --scout"
PASEO_WORKSPACE_ID=wks_inherited PASEO_AGENT_ID=agent1 PASEO_TERMINAL_ID=t1 run bin/fm-spawn.sh "$id2" "$PROJ" --scout | tail -4
echo "--- $id2 meta backend line: $(grep '^backend=' "$LAB/state/$id2.meta" 2>/dev/null || echo '(none => tmux)')"
echo "--- paseo CLI calls during this spawn (read-only inventory of the OTHER, paseo task's endpoint; no create):"; tail -n +$((calls_before+1)) "$FM_FAKE_PASEO_STATE/calls.log"
echo
echo "========== S6: teardown kills the paseo tab and retires the home-clone workspace"
echo "\$ fm-teardown.sh $id"; run bin/fm-teardown.sh "$id" | tail -6
echo "--- events: $(tr '\n' ';' < "$FM_FAKE_PASEO_STATE/events.log" 2>/dev/null)"
echo "--- remaining terminals: $(jq -c . "$FM_FAKE_PASEO_STATE/term.json")  workspaces: $(jq -c . "$FM_FAKE_PASEO_STATE/ws.json")"
echo "--- fake paseo projects left: $(cat "$FM_FAKE_PASEO_STATE/proj.json")"
echo "LAB=$LAB"
chmod -R u+w "$LAB" /tmp/fm-paseo-ext-r1* /tmp/fm-autodetect-r1* 2>/dev/null; rm -rf "$LAB" /tmp/fm-paseo-ext-r1* /tmp/fm-autodetect-r1*
echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes )"
