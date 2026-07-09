#!/usr/bin/env bash
# v0.38 §5.2 gates A1-A5 (+ lease refuse, tip-conflict) and §6 interruption scenarios A-P1..A-P3
# — EXECUTES scripts/adopt-reconcile.py against REAL git repos. Adopt reconstructs an uncleanly
# interrupted run GIT-FIRST (consuming v0.37.5 F7 for tips + v0.38 F8 for in-flight tracks) and
# FAILS CLOSED on anything it cannot resolve. Locks:
#   A1  run-state test_tip is stale, the branch advanced 3 commits -> adopt reconciles to the
#       GIT tip (git wins), records it, and does NOT build on the stale tip (RUN2 replay);
#   A2  a slice 'integrated' in run-state -> skipped (no rework, no re-verify);
#   A3  in_progress with BOTH tracks ahead of wave_base -> reaped + carried to assembly, not
#       re-dispatched;
#   A4  in_progress with ONE track branch missing -> ONLY that track re-dispatched blind; the
#       present track is kept;
#   A5  in_progress but NEITHER track carries work (irreconcilable) -> ESCALATE + stop (exit 2),
#       escalations.md written; adopt never marks the slice done;
#   LEASE  a LIVE lease held by another session -> REFUSE (exit 2); an EXPIRED lease is stealable;
#   CONFLICT  a recorded reported_commit that conflicts irreconcilably with the live tip -> ESCALATE;
#   A-P1  context-death after dispatch, before any track reports (both tracks in-flight bg) -> reap both;
#   A-P2  one bg branch advanced, run-state not updated (the RUN2 drift) -> reconciled to git;
#   A-P3  abandoned status=running, expired lease, partially-assembled slice -> stealable + classified.
# Invariants asserted throughout: run_id stable; integrated never reworked; in-flight reaped not
# re-rolled; run-state reconciled to git; NO false green; irreconcilable escalates not guesses.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; AD="$PLUGIN/scripts/adopt-reconcile.py"; SM="$PLUGIN/scripts/subagent-manifest.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
python3 -c 'import jsonschema' 2>/dev/null || { echo "SKIP"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
NOW=2026-07-09T12:00:00Z
LIVE_LEASE='{"holder":"r1","acquired_at":"2026-07-09T11:00:00Z","expires_at":"2999-01-01T00:00:00Z"}'
DEAD_LEASE='{"holder":"r1","acquired_at":"2026-07-08T00:00:00Z","expires_at":"2026-07-08T01:00:00Z"}'

# newrepo <dir>  -> a git repo with a base commit; prints the base OID via $WB (global)
newrepo(){ local R="$1"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  mkdir -p "$R/.parallax/demo"; echo base > "$R/f.txt"; git -C "$R" add -A; git -C "$R" commit -qm base
  WB=$(git -C "$R" rev-parse HEAD); }
# track <repo> <name> <ncommits>  -> creates feature/demo-<name> off $WB with N commits; prints tip
track(){ local R="$1" N="$2" K="$3" i; git -C "$R" switch -q -c "feature/demo-$N" "$WB"
  for ((i=0;i<K;i++)); do echo "$N$i" >> "$R/f.txt"; git -C "$R" commit -qam "$N$i"; done
  git -C "$R" switch -q master 2>/dev/null || git -C "$R" switch -q main
  git -C "$R" rev-parse "feature/demo-$N"; }
jq_get(){ python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$1" "$2"; }

###########################################################################################
# A1 / A-P2 — stale tip drift reconciled to git (RUN2 replay), NO rework, run_id stable
###########################################################################################
R="$T/a1"; newrepo "$R"
git -C "$R" switch -q -c feature/demo-S6-test "$WB"; echo c1>>"$R/f.txt"; git -C "$R" commit -qam c1; STALE=$(git -C "$R" rev-parse HEAD)
echo c2>>"$R/f.txt"; git -C "$R" commit -qam c2; echo c3>>"$R/f.txt"; git -C "$R" commit -qam c3
LIVE_T=$(git -C "$R" rev-parse feature/demo-S6-test)
git -C "$R" switch -q -c feature/demo-S6-code "$WB"; echo cc>>"$R/f.txt"; git -C "$R" commit -qam cc; LIVE_C=$(git -C "$R" rev-parse feature/demo-S6-code)
git -C "$R" switch -q master 2>/dev/null || git -C "$R" switch -q main
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[{"id":"S6","status":"in_progress","code_tip":"$LIVE_C","test_tip":"$STALE","wave_base":"$WB"}],
 "integrated":[],"updated_at":"2026-07-09T00:00:00Z"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" --write-back --session-id newS >/tmp/parallax_ad_a1 || fail "A1: adopt refused an adoptable run: $(cat /tmp/parallax_ad_a1)"
grep -qF '"verdict": "adoptable"' /tmp/parallax_ad_a1 || fail "A1: not adoptable: $(cat /tmp/parallax_ad_a1)"
NEW_T=$(jq_get "$R/.parallax/demo/run-state.json" "[s for s in d['slices'] if s['id']=='S6'][0]['test_tip']")
[ "$NEW_T" = "$LIVE_T" ] || fail "A1: test_tip not reconciled to git ($NEW_T != $LIVE_T)"
[ "$NEW_T" != "$STALE" ] || fail "A1: adopt kept the STALE tip"
[ "$(jq_get "$R/.parallax/demo/run-state.json" "d['run_id']")" = "r1" ] || fail "A1: run_id not stable"
grep -qF "in_progress_recoverable" /tmp/parallax_ad_a1 || fail "A1: S6 not classified recoverable"

###########################################################################################
# A2 — an integrated slice is SKIPPED (no rework); A3 both-tracks-ahead -> reap; A4 one missing
# A5 neither -> escalate; all in one repo with an expired (stealable) lease.
###########################################################################################
R="$T/a2345"; newrepo "$R"
S6C=$(track "$R" S6-code 1); S6T=$(track "$R" S6-test 1)     # A3: both ahead
S7C=$(track "$R" S7-code 1)                                   # A4: only code (test branch absent)
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[
   {"id":"S1","status":"integrated"},
   {"id":"S6","status":"in_progress","code_tip":"$WB","test_tip":"$S6T","wave_base":"$WB"},
   {"id":"S7","status":"in_progress","code_tip":"$S7C","test_tip":"$WB","wave_base":"$WB"},
   {"id":"S8","status":"in_progress","code_tip":"$WB","test_tip":"$WB","wave_base":"$WB"}],
 "integrated":["S1"],"updated_at":"2026-07-09T00:00:00Z"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" --write-back --session-id newS >/tmp/parallax_ad_2345; RC=$?
[ "$RC" -eq 2 ] || fail "A5: adopt did not fail closed on S8 (rc=$RC): $(cat /tmp/parallax_ad_2345)"
python3 - /tmp/parallax_ad_2345 <<'PY' || fail "A2/A3/A4/A5 classification wrong"
import json,sys
d=json.load(open(sys.argv[1])); by={s['id']:s for s in d['slices']}
assert d['verdict']=='escalate', d['verdict']
assert by['S1']['class']=='integrated' and by['S1']['action']=='skip'                    # A2
assert by['S6']['class']=='in_progress_recoverable' and by['S6']['action']=='reap-and-assemble'  # A3
assert by['S7']['class']=='in_progress_missing_track' and by['S7']['redispatch']==['test'] # A4
assert by['S7'].get('keep_present')=='code'                                              # A4 present kept
assert by['S8']['class']=='escalate'                                                     # A5
PY
grep -q "adopt escalation" "$R/.parallax/demo/escalations.md" || fail "A5: escalations.md not written"
# A2 no-rework invariant: S1 stays integrated in run-state (adopt did not touch it)
[ "$(jq_get "$R/.parallax/demo/run-state.json" "[s for s in d['slices'] if s['id']=='S1'][0]['status']")" = "integrated" ] || fail "A2: integrated slice mutated"

###########################################################################################
# LEASE — a LIVE lease is refused (exit 2), before any classification
###########################################################################################
R="$T/lease"; newrepo "$R"
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$LIVE_LEASE,
 "slices":[{"id":"S1","status":"pending"}],"integrated":[],"updated_at":"t"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" >/tmp/parallax_ad_lease; RC=$?
[ "$RC" -eq 2 ] || fail "LEASE: live lease not refused (rc=$RC)"
grep -qF '"verdict": "refuse-live-lease"' /tmp/parallax_ad_lease || fail "LEASE: wrong verdict: $(cat /tmp/parallax_ad_lease)"

###########################################################################################
# CONFLICT — a manifest reported_commit that conflicts with the live tip -> escalate (exit 2)
###########################################################################################
R="$T/conf"; newrepo "$R"
S6T=$(track "$R" S6-test 1); S6C=$(track "$R" S6-code 1)
DIVV=$(track "$R" divergent 1)   # a commit off wave_base, not an ancestor of S6-test tip
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[{"id":"S6","status":"in_progress","code_tip":"$S6C","test_tip":"$S6T","wave_base":"$WB"}],
 "integrated":[],"updated_at":"t"}
J
python3 "$SM" record "$R/.parallax/demo/subagents.json" --run-id r1 --slug demo --slice S6 --role test-writer \
  --branch feature/demo-S6-test --wave-base "$WB" --session-id dead --mode background \
  --status reported --reported-commit "$DIVV" >/dev/null || fail "CONFLICT: manifest setup"
python3 "$AD" --repo "$R" --slug demo --now "$NOW" >/tmp/parallax_ad_conf; RC=$?
[ "$RC" -eq 2 ] || fail "CONFLICT: not failed closed (rc=$RC): $(cat /tmp/parallax_ad_conf)"
grep -qF '"verdict": "escalate"' /tmp/parallax_ad_conf || fail "CONFLICT: wrong verdict"

###########################################################################################
# A-P1 — context-death after dispatch, before any report: both tracks in-flight BACKGROUND,
# branches carry commits but the manifest still says 'dispatched'. Adopt reaps both, no false green.
###########################################################################################
R="$T/ap1"; newrepo "$R"
S6C=$(track "$R" S6-code 1); S6T=$(track "$R" S6-test 1)
M="$R/.parallax/demo/subagents.json"
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role blind-coder --branch feature/demo-S6-code --wave-base "$WB" --session-id dead --mode background >/dev/null
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role test-writer --branch feature/demo-S6-test --wave-base "$WB" --session-id dead --mode background >/dev/null
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[{"id":"S6","status":"in_progress","code_tip":"$S6C","test_tip":"$S6T","wave_base":"$WB"}],
 "integrated":[],"updated_at":"t"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" --write-back --session-id newS >/tmp/parallax_ad_ap1 || fail "A-P1: refused adoptable: $(cat /tmp/parallax_ad_ap1)"
grep -qF '"class": "in_progress_recoverable"' /tmp/parallax_ad_ap1 || fail "A-P1: not recoverable"
python3 - "$M" "$S6C" "$S6T" <<'PY' || fail "A-P1: both bg tracks not reaped off git"
import json,sys
m=json.load(open(sys.argv[1])); by={(e['slice'],e['role']):e for e in m['entries']}
assert by[('S6','blind-coder')]['status']=='reaped' and by[('S6','blind-coder')]['reported_commit']==sys.argv[2]
assert by[('S6','test-writer')]['status']=='reaped' and by[('S6','test-writer')]['reported_commit']==sys.argv[3]
PY
# NO false green: S6 stays in_progress in run-state (adopt classified, did not mark integrated/green)
[ "$(jq_get "$R/.parallax/demo/run-state.json" "[s for s in d['slices'] if s['id']=='S6'][0]['status']")" = "in_progress" ] || fail "A-P1: false green — S6 status changed"

###########################################################################################
# A-P3 — abandoned status=running, EXPIRED lease, partially-assembled slice (one track ahead,
# one behind). Lease is stealable; slice classified missing-track (re-dispatch only the behind one).
###########################################################################################
R="$T/ap3"; newrepo "$R"
S9C=$(track "$R" S9-code 2)      # code ahead
git -C "$R" branch feature/demo-S9-test "$WB"   # test branch exists but is EMPTY (== wave_base)
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[{"id":"S9","status":"in_progress","code_tip":"$S9C","test_tip":"$WB","wave_base":"$WB"}],
 "integrated":[],"updated_at":"t"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" --write-back --session-id newS >/tmp/parallax_ad_ap3 || fail "A-P3: refused: $(cat /tmp/parallax_ad_ap3)"
python3 - /tmp/parallax_ad_ap3 <<'PY' || fail "A-P3: classification/lease wrong"
import json,sys
d=json.load(open(sys.argv[1]))
assert d['lease']['state']=='expired-stealable', d['lease']
s9=[s for s in d['slices'] if s['id']=='S9'][0]
assert s9['class']=='in_progress_missing_track' and s9['redispatch']==['test'], s9
assert s9['keep_present']=='code'
PY

###########################################################################################
# STALE-TRACK — a manifest entry naming a VANISHED branch on a slice that is otherwise
# recoverable from the canonical git branches is SURFACED (stale_dispatched_tracks), never
# silently dropped, and NOT over-escalated (the run stays adoptable — git is the truth).
###########################################################################################
R="$T/stale"; newrepo "$R"
S6C=$(track "$R" S6-code 1); S6T=$(track "$R" S6-test 1)
python3 "$SM" record "$R/.parallax/demo/subagents.json" --run-id r1 --slug demo --slice S6 --role blind-coder \
  --branch feature/demo-S6-oldcode --wave-base "$WB" --session-id dead --mode background >/dev/null || fail "STALE: setup"
cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r1","slug":"demo","epic":"e","base_tip":"$WB","status":"running","lock":$DEAD_LEASE,
 "slices":[{"id":"S6","status":"in_progress","code_tip":"$S6C","test_tip":"$S6T","wave_base":"$WB"}],
 "integrated":[],"updated_at":"t"}
J
python3 "$AD" --repo "$R" --slug demo --now "$NOW" >/tmp/parallax_ad_stale || fail "STALE: refused an adoptable run"
python3 - /tmp/parallax_ad_stale <<'PY' || fail "STALE: vanished dispatched track not surfaced (or over-escalated)"
import json,sys
d=json.load(open(sys.argv[1]))
assert d['verdict']=='adoptable', d['verdict']                          # not over-escalated
st=d.get('stale_dispatched_tracks') or []
assert any(t['branch']=='feature/demo-S6-oldcode' for t in st), st      # surfaced, not silently dropped
PY

echo "t_adopt OK"
