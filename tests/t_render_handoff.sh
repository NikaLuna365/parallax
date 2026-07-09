#!/usr/bin/env bash
# v0.38 §5.3 gate H1 — EXECUTES scripts/render-handoff.py against a run-state + manifest fixture.
# The machine handoff that replaces the hand-written RUN-HANDOFF.md. Locks:
#   H1a. the render NAMES every in-flight track's branch AND commit;
#   H1b. it contains the EXACT resume command `/parallax:run --adopt <slug>`;
#   H1c. it contains NO free-text field an operator must fill (no TODO/FIXME/<placeholder>);
#   H1d. it is DETERMINISTIC — same inputs render byte-identical output (timestamp from run-state).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; RH="$PLUGIN/scripts/render-handoff.py"; SM="$PLUGIN/scripts/subagent-manifest.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

R="$T/repo"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/.parallax/demo/evidence"
echo base > "$R/f.txt"; git -C "$R" add -A; git -C "$R" commit -qm base; WB=$(git -C "$R" rev-parse HEAD)
git -C "$R" switch -q -c feature/demo-S6-test; echo w>>"$R/f.txt"; git -C "$R" commit -qam w; T6=$(git -C "$R" rev-parse HEAD)
git -C "$R" switch -q -c feature/demo-S6-code "$WB"; echo c>>"$R/f.txt"; git -C "$R" commit -qam c; C6=$(git -C "$R" rev-parse HEAD)
git -C "$R" switch -q master 2>/dev/null || git -C "$R" switch -q main
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running",
 "lock":{"holder":"r1","acquired_at":"t","expires_at":"t2"},
 "slices":[{"id":"S1","status":"integrated"},
           {"id":"S5","status":"green-unverified","arbiter_verdict":"green","verified_diff":"$WB","wave_base":"$WB"},
           {"id":"S6","status":"in_progress","code_tip":"$C6","test_tip":"$T6","wave_base":"$WB"}],
 "integrated":["S1"],"updated_at":"2026-07-09T00:00:00Z"}
J
M="$R/.parallax/demo/subagents.json"
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role blind-coder --branch feature/demo-S6-code --wave-base "$WB" --session-id dead --mode background --status reported --reported-commit "$C6" >/dev/null
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role test-writer --branch feature/demo-S6-test --wave-base "$WB" --session-id dead --mode background --status reported --reported-commit "$T6" >/dev/null

H="$R/.parallax/demo/handoff.md"
python3 "$RH" --repo "$R" --slug demo --out "$H" >/dev/null || fail "render failed"

# H1a — every in-flight branch + commit named
grep -qF "feature/demo-S6-code" "$H" || fail "H1a: S6-code branch not named"
grep -qF "feature/demo-S6-test" "$H" || fail "H1a: S6-test branch not named"
grep -qF "$C6" "$H" || fail "H1a: S6-code commit not named"
grep -qF "$T6" "$H" || fail "H1a: S6-test commit not named"
# H1b — exact adopt command
grep -qF "/parallax:run --adopt demo" "$H" || fail "H1b: exact --adopt command missing"
# H1c — no operator free-text placeholder
grep -qiE 'TODO|FIXME|FILL[ _-]?IN|<[A-Za-z_]+>' "$H" && fail "H1c: a free-text placeholder is present" || true
# owed verification + integrated surfaced (completeness)
grep -qF "S5" "$H" || fail "H1: owed verification S5 not surfaced"
grep -qF "S1" "$H" || fail "H1: integrated S1 not surfaced"
# H1d — deterministic
python3 "$RH" --repo "$R" --slug demo --out "$H.2" >/dev/null || fail "second render failed"
diff -q "$H" "$H.2" >/dev/null || fail "H1d: render is not deterministic"

echo "t_render_handoff OK"
