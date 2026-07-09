#!/usr/bin/env bash
# v0.38 §5.1 gate M1 — EXECUTES scripts/subagent-manifest.py against a REAL git repo.
# The enabling artifact for --adopt: a machine record of every dispatched track. Locks:
#   M1a. record writes a schema-valid entry; a second record for the SAME (slice, role)
#        UPDATES it in place (no duplicate) — the manifest always names the current state;
#   M1b. record with a mismatched run_id/slug is REFUSED (exit 2) — a track cannot be filed
#        under another run;
#   M1c. reconcile: an entry whose branch does NOT exist is STALE on next read, never silently
#        trusted (--write-back persists status=stale);
#   M1d. reconcile: a background track whose branch is AHEAD of wave_base is reap-eligible and
#        its live tip is recorded as reported_commit (--write-back persists status=reaped) —
#        the missed cross-session notification, replaced by reading git;
#   M1e. reconcile: a recorded reported_commit that conflicts irreconcilably with the live tip
#        is surfaced (any_conflict), never silently overwritten.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; SM="$PLUGIN/scripts/subagent-manifest.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
python3 -c 'import jsonschema' 2>/dev/null || { echo "SKIP"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

R="$T/repo"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo base > "$R/f.txt"; git -C "$R" add -A; git -C "$R" commit -qm base
WB=$(git -C "$R" rev-parse HEAD)
git -C "$R" branch feature/demo-S6-code
git -C "$R" switch -q -c feature/demo-S6-test; echo w >> "$R/f.txt"; git -C "$R" commit -qam w
TIP=$(git -C "$R" rev-parse feature/demo-S6-test)
git -C "$R" switch -q master 2>/dev/null || git -C "$R" switch -q main
M="$R/.parallax/demo/subagents.json"

# --- M1a) record + in-place update (no duplicate)
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role blind-coder \
  --branch feature/demo-S6-code --wave-base "$WB" --session-id sA --mode background >/dev/null || fail "M1a: first record failed"
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role blind-coder \
  --branch feature/demo-S6-code --wave-base "$WB" --session-id sA --mode background --status reported >/dev/null || fail "M1a: update failed"
python3 - "$M" <<'PY' || fail "M1a: duplicate entry, or manifest not schema-valid"
import json, sys, jsonschema
m=json.load(open(sys.argv[1]))
jsonschema.validate(m, json.load(open("assets/subagents.schema.json")))
n=[e for e in m["entries"] if e["slice"]=="S6" and e["role"]=="blind-coder"]
assert len(n)==1, f"expected 1 in-place entry, got {len(n)}"
assert n[0]["status"]=="reported"
PY

# --- M1b) mismatched run_id refused
python3 "$SM" record "$M" --run-id WRONG --slug demo --slice S6 --role arbiter \
  --branch feature/demo --wave-base "$WB" --session-id sA --mode foreground >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "M1b: mismatched run_id not refused (rc=$RC)"

# --- add the test-writer (advanced) + a bogus-branch track
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role test-writer \
  --branch feature/demo-S6-test --wave-base "$WB" --session-id sA --mode background >/dev/null || fail "record test-writer"
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S7 --role blind-coder \
  --branch feature/demo-S7-code --wave-base "$WB" --session-id sA --mode background >/dev/null || fail "record S7"

# --- M1c + M1d) reconcile: stale missing branch, reap advanced branch
python3 "$SM" reconcile "$M" --repo "$R" --write-back >/tmp/parallax_sm_rec || fail "M1cd: reconcile failed"
grep -qF '"any_stale": true' /tmp/parallax_sm_rec || fail "M1c: missing branch not flagged stale: $(cat /tmp/parallax_sm_rec)"
python3 - "$M" "$TIP" <<'PY' || fail "M1cd: stale/reap not persisted"
import json, sys
m=json.load(open(sys.argv[1])); tip=sys.argv[2]
by={(e["slice"],e["role"]):e for e in m["entries"]}
assert by[("S7","blind-coder")]["status"]=="stale", by[("S7","blind-coder")]         # M1c
tw=by[("S6","test-writer")]
assert tw["status"]=="reaped" and tw["reported_commit"]==tip, tw                      # M1d
PY

# --- M1e) a conflicting recorded reported_commit is surfaced (not silently overwritten)
git -C "$R" switch -q -c divergent "$WB"; echo x >> "$R/f.txt"; git -C "$R" commit -qam div
DIV=$(git -C "$R" rev-parse HEAD); git -C "$R" switch -q master 2>/dev/null || git -C "$R" switch -q main
python3 "$SM" record "$M" --run-id r1 --slug demo --slice S6 --role test-writer \
  --branch feature/demo-S6-test --wave-base "$WB" --session-id sA --mode background \
  --status reported --reported-commit "$DIV" >/dev/null || fail "M1e: record conflict setup"
python3 "$SM" reconcile "$M" --repo "$R" >/tmp/parallax_sm_conf || fail "M1e: reconcile failed"
grep -qF '"any_conflict": true' /tmp/parallax_sm_conf || fail "M1e: conflict not surfaced: $(cat /tmp/parallax_sm_conf)"

echo "t_subagent_manifest OK"
