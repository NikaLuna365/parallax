#!/usr/bin/env bash
# v0.39 §5.1 gates HG1/HG2/HG3 — EXECUTES scripts/finalize-handdriven.py against a REAL git repo.
# Makes the v0.38 gates fire on the HAND path (the whole v0.38.1 production window bypassed them).
# Locks (each see-it-fail-first: neuter the mechanism -> the corresponding case flips):
#   HG3. a stale tip (recorded_tip != git rev-parse <branch>) REFUSES (B1 on the hand path);
#   HG2. a hand-committed MALFORMED verdict is REJECTED by the merge-ledger schema-gate (provider
#        error, never a merge-unblock); a valid verdict passes the gate;
#   HG1. after HG2 gates GREEN, the receipts are emitted and audit-slice runs; a slice with NO
#        receipts (emit neutered via --no-emit) FAILS CLOSED (E1 on the hand path);
#   plus the happy path finalizes (exit 0) and re-stamps run-evidence to the live plugin version (§5.5).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; FH="$PLUGIN/scripts/finalize-handdriven.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
python3 -c 'import jsonschema' 2>/dev/null || { echo "SKIP"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

R="$T/r"; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)
git -C "$R" switch -q -c feature/demo; echo b >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm work
TIP=$(git -C "$R" rev-parse feature/demo); git -C "$R" switch -q main
EV="$R/.parallax/demo/evidence"; mkdir -p "$EV" "$R/.parallax/demo"
# a stale (0.36.1) run-evidence.json — restamp must bump it to the live plugin version
LIVE=$(python3 -c "import json;print(json.load(open('$PLUGIN/.claude-plugin/plugin.json'))['version'])")
cat > "$EV/run-evidence.json" <<J
{"schema_version":"parallax-run-evidence-v1","plugin":{"name":"parallax","version":"0.36.1"},
 "run":{"run_id":"r1","slug":"demo","command_entry":"run","started_at":"t","updated_at":"t","status":"frozen-spec"},
 "repo":{"root":null,"branch":null,"base_tip":null,"feature_tip":null,"dirty_at_start":null,"dirty_at_end":null},
 "artifacts":{"spec":null,"slices":null,"validation":null,"slices_lock":null,"run_state":null},
 "capabilities_exercised":{"existing_affordance_review":null,"architecture_fitness":null,"project_scout":null,"intake_handoff":null,"safe_resolution":null},
 "evidence_limits":[]}
J
echo '{"verdict":"pass","findings":[]}' > "$R/.parallax/demo/good.raw.json"
echo '{"verdict":"ok"}'                 > "$R/.parallax/demo/bad.raw.json"   # schema-invalid (no findings)
DIFF=$(printf 'a%.0s' {1..40})
fh(){ python3 "$FH" --repo "$R" --slug demo --evidence-dir "$EV" --run-id r1 --slice "$1" \
        --branch feature/demo --recorded-tip "$2" --raw-verdict "$3" --ledger "$4" --current-diff "$DIFF" "${@:5}"; }

# --- happy path -> exit 0, all gates ok, restamp
fh S1 "$TIP" "$R/.parallax/demo/good.raw.json" "$R/.parallax/demo/S1.led.json" >/tmp/parallax_fh1 2>&1 || fail "happy path refused: $(cat /tmp/parallax_fh1)"
grep -qF '"verdict": "finalized"' /tmp/parallax_fh1 || fail "happy path not finalized: $(cat /tmp/parallax_fh1)"
NEWV=$(python3 -c "import json;print(json.load(open('$EV/run-evidence.json'))['plugin']['version'])")
[ "$NEWV" = "$LIVE" ] || fail "§5.5 restamp: run-evidence version $NEWV != live $LIVE"
python3 -c "import json;assert json.load(open('$EV/run-evidence.json'))['run']['status']!='frozen-spec'" || fail "§5.5 status still frozen-spec"

# --- HG3: stale tip -> refuse (exit 2)
fh S2 "$BASE" "$R/.parallax/demo/good.raw.json" "$T/l2.json" >/tmp/parallax_fh3 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "HG3: stale tip not refused (rc=$RC)"
grep -qF 'HG3' /tmp/parallax_fh3 || fail "HG3: wrong reason: $(cat /tmp/parallax_fh3)"

# --- HG2: malformed hand-committed verdict -> rejected (exit 2)
fh S3 "$TIP" "$R/.parallax/demo/bad.raw.json" "$T/l3.json" >/tmp/parallax_fh2 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "HG2: malformed verdict not rejected (rc=$RC)"
grep -qF 'HG2' /tmp/parallax_fh2 || fail "HG2: wrong reason: $(cat /tmp/parallax_fh2)"

# --- HG1: receipts neutered (--no-emit) into a FRESH evidence dir -> audit-slice fails closed (exit 2).
# HG3 and HG2 pass (valid tip + valid verdict), so reaching HG1 with no emitted receipt proves the
# fail-closed E1 check on the hand path (neuter = --no-emit).
mkdir -p "$T/ev2"
python3 "$FH" --repo "$R" --slug demo --evidence-dir "$T/ev2" --run-id r1 --slice S4 --branch feature/demo \
  --recorded-tip "$TIP" --raw-verdict "$R/.parallax/demo/good.raw.json" --ledger "$T/l4b.json" \
  --current-diff "$DIFF" --no-emit >/tmp/parallax_fh4 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "HG1: missing-receipt slice not failed closed (rc=$RC): $(cat /tmp/parallax_fh4)"
grep -qF 'HG1' /tmp/parallax_fh4 || fail "HG1: wrong reason: $(cat /tmp/parallax_fh4)"

echo "t_finalize_handdriven OK"
