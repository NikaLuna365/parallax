#!/usr/bin/env bash
# v0.37.5 6.1 / TRIAGE gate B1 — EXECUTES scripts/resume-reconcile.py against a REAL git repo,
# replaying the RUN2 live drift: run-state recorded S6 test_tip=ced5b80 while the live branch
# had advanced 3 commits (2 arbiter RED rounds + a re-blindfold) that were never written back.
# Locks:
#   B1a. recorded tips == live tips -> exit 0, verdict consistent;
#   B1b. the branch advances past the recorded tip -> WITHOUT --write-back the resume is
#        REFUSED (exit 2) with the exact per-slice drift — run-state is never silently
#        trusted over git;
#   B1c. --write-back adopts the REAL git tips into run-state (git is the truth), refreshes
#        updated_at, exits 0, and instructs the caller to emit session_handoff + re-commit;
#   B1d. integrated/parked slices are ignored (their tips no longer drive work);
#   B1e. a recorded tip whose track branch no longer exists is drift (missing-branch) and
#        cannot be silently written back.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; RR="$PLUGIN/scripts/resume-reconcile.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

R="$T/repo"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/.parallax/demo"
echo base > "$R/f.txt"; git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" branch feature/demo-S6-code; git -C "$R" branch feature/demo-S6-test
CODE_TIP=$(git -C "$R" rev-parse feature/demo-S6-code)
TEST_TIP=$(git -C "$R" rev-parse feature/demo-S6-test)
rs(){ cat > "$R/.parallax/demo/run-state.json" <<J
{"run_id":"r","slug":"demo","epic":"e","base_tip":"$CODE_TIP","status":"paused-on-limit",
 "paused":{"service":"claude","at":"t"},
 "slices":[{"id":"S6","status":"in_progress","code_tip":"$CODE_TIP","test_tip":"$1","wave_base":"$CODE_TIP"},
           {"id":"S1","status":"integrated","test_tip":"$2"}],
 "integrated":["S1"],"updated_at":"2026-07-08T12:08:00Z"}
J
}

# --- B1a) consistent -> proceed
rs "$TEST_TIP" "$TEST_TIP"
python3 "$RR" --repo "$R" --slug demo >/tmp/parallax_rr1 || fail "B1a: consistent state refused: $(cat /tmp/parallax_rr1)"
grep -qF '"verdict": "consistent"' /tmp/parallax_rr1 || fail "B1a: wrong verdict: $(cat /tmp/parallax_rr1)"

# --- B1b) the RUN2 replay: the test branch advances 3 commits past the recorded tip -> REFUSED
git -C "$R" switch -q feature/demo-S6-test
echo red2 >> "$R/f.txt"; git -C "$R" commit -qam "arbiter RED round 2 fixes"
echo reblind >> "$R/f.txt"; git -C "$R" commit -qam "re-blindfold"
echo red3 >> "$R/f.txt"; git -C "$R" commit -qam "arbiter RED round 3 fixes"
git -C "$R" switch -q main 2>/dev/null || git -C "$R" switch -q master
LIVE=$(git -C "$R" rev-parse feature/demo-S6-test)
python3 "$RR" --repo "$R" --slug demo >/tmp/parallax_rr2; RC=$?
[ "$RC" -eq 2 ] || fail "B1b: stale checkpoint was trusted (rc=$RC): $(cat /tmp/parallax_rr2)"
grep -qF '"kind": "tip-drift"' /tmp/parallax_rr2 || fail "B1b: drift not reported: $(cat /tmp/parallax_rr2)"
grep -qF "$LIVE" /tmp/parallax_rr2 || fail "B1b: live tip not named: $(cat /tmp/parallax_rr2)"

# --- B1c) --write-back adopts the REAL tips (git is the truth) and demands session_handoff
python3 "$RR" --repo "$R" --slug demo --write-back >/tmp/parallax_rr3 || fail "B1c: write-back failed: $(cat /tmp/parallax_rr3)"
grep -qF '"verdict": "reconciled"' /tmp/parallax_rr3 || fail "B1c: wrong verdict: $(cat /tmp/parallax_rr3)"
grep -qF 'session_handoff' /tmp/parallax_rr3 || fail "B1c: no session_handoff instruction: $(cat /tmp/parallax_rr3)"
python3 - "$R/.parallax/demo/run-state.json" "$LIVE" <<'PY' || fail "B1c: real tip not written back / updated_at stale"
import json,sys
d=json.load(open(sys.argv[1]))
s6=[s for s in d["slices"] if s["id"]=="S6"][0]
assert s6["test_tip"]==sys.argv[2], s6["test_tip"]
assert d["updated_at"] != "2026-07-08T12:08:00Z"
PY
python3 "$RR" --repo "$R" --slug demo >/dev/null || fail "B1c2: reconciled state still refused"

# --- B1d) integrated slices with stale tips are IGNORED (S1 above carries a stale tip throughout)
# (already proven: B1a/B1c passed while S1.test_tip was stale)

# --- B1e) a missing track branch is drift and cannot be silently written back
git -C "$R" branch -D feature/demo-S6-code >/dev/null
python3 "$RR" --repo "$R" --slug demo >/tmp/parallax_rr4; RC=$?
[ "$RC" -eq 2 ] || fail "B1e: missing branch not flagged (rc=$RC)"
grep -qF 'missing-branch' /tmp/parallax_rr4 || fail "B1e: wrong kind: $(cat /tmp/parallax_rr4)"
python3 "$RR" --repo "$R" --slug demo --write-back >/tmp/parallax_rr5; RC=$?
[ "$RC" -eq 2 ] || fail "B1e: missing branch was silently written back (rc=$RC)"

echo "t_resume_reconcile OK"
