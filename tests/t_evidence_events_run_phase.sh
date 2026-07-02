#!/usr/bin/env bash
# v0.37.3 F5 — EXECUTES scripts/evidence-event.py against a temp .parallax/demo/evidence/.
# Locks the fix for "events.jsonl stops at spec_frozen on 3/3 production runs":
#   1. a simulated BUILD-phase timeline appends and schema-validates: slice_dispatched,
#      arbiter_iteration_started/finished, codex_round_started/finished, slice_green,
#      run_completed (every line re-validated independently of the helper);
#   2. run-evidence.json moves frozen-spec -> running -> complete via update-run, stays
#      schema-valid, and updated_at refreshes;
#   3. append-only holds: earlier lines are byte-identical after later appends;
#   4. fail-closed: an unknown event_type writes NOTHING; a run_id mismatching the sibling
#      run-evidence.json is refused; update-run refuses a wrong --run-id and an invalid
#      status; a missing run-evidence.json is not silently created.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; E="$PLUGIN/scripts/evidence-event.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo "t_evidence_events_run_phase SKIP (jsonschema not installed — the helper itself fails closed without it)"; exit 2; }
EV="$T/.parallax/demo/evidence"; mkdir -p "$EV"
JL="$EV/events.jsonl"; RE="$EV/run-evidence.json"

# Phase-1-produced run-evidence.json, frozen at spec (the exact live-run starting state)
cat > "$RE" <<'JSON'
{
  "schema_version": "parallax-run-evidence-v1",
  "plugin": {"name": "parallax", "version": "0.37.3"},
  "run": {"run_id": "r-1", "slug": "demo", "command_entry": "run",
          "started_at": "2026-07-02T10:00:00Z", "updated_at": "2026-07-02T10:00:00Z",
          "status": "frozen-spec"},
  "repo": {"root": "/tmp/demo", "branch": "feature/demo", "base_tip": "aaa", "feature_tip": null,
           "dirty_at_start": false, "dirty_at_end": null},
  "artifacts": {"spec": ".parallax/demo/spec.md", "slices": ".parallax/demo/slices.md",
                "validation": ".parallax/demo/validation.md", "slices_lock": ".parallax/demo/slices.lock",
                "run_state": ".parallax/demo/run-state.json"},
  "capabilities_exercised": {"existing_affordance_review": true, "architecture_fitness": true,
                             "project_scout": null, "intake_handoff": null, "safe_resolution": null},
  "evidence_limits": []
}
JSON
AP(){ python3 "$E" append "$EV" --run-id r-1 --slug demo "$@"; }

# --- 2a) frozen-spec -> running at build start
python3 "$E" update-run "$EV" --status running --run-id r-1 --slug demo >/dev/null || fail "2a: update-run -> running failed"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["run"]["status"]=="running"' "$RE" || fail "2a: status not running"

# --- 1) the build-phase timeline the live audit found missing
AP --event-type slice_dispatched          --actor main    --summary "S1 dispatched to both blind tracks" >/dev/null || fail "1: slice_dispatched"
AP --event-type test_writer_red           --actor test-writer --summary "S1 suite RED for the spec'd reason" --branch feature/demo-test >/dev/null || fail "1: test_writer_red"
AP --event-type blind_coder_done          --actor blind-coder --summary "S1 implementation done-gate green" --branch feature/demo-code >/dev/null || fail "1: blind_coder_done"
AP --event-type arbiter_iteration_started --actor arbiter --summary "S1 arbiter iteration 1 started" >/dev/null || fail "1: arbiter_iteration_started"
AP --event-type arbiter_iteration_finished --actor arbiter --summary "S1 arbiter iteration 1 finished: green" \
   --artifact-paths '{"full_check_log": ".parallax/demo/logs/s1-full.txt"}' >/dev/null || fail "1: arbiter_iteration_finished"
AP --event-type codex_round_started       --actor verifier --summary "S1 post-green codex round 1 started" >/dev/null || fail "1: codex_round_started"
AP --event-type codex_round_finished      --actor verifier --summary "S1 codex round 1 finished: pass (self-continued: no — initial round)" \
   --artifact-paths '{"review_ledger": ".parallax/demo/reviews/S1.json"}' >/dev/null || fail "1: codex_round_finished"
AP --event-type slice_green               --actor main    --summary "S1 integrated: arbiter green + verifier pass" >/dev/null || fail "1: slice_green"
HALF=$(cat "$JL")   # snapshot for the append-only check
AP --event-type run_completed             --actor main    --summary "run complete: 1/1 slices integrated" >/dev/null || fail "1: run_completed"

# every line validates independently (not just the helper's own claim)
python3 - "$JL" "$PLUGIN/assets/run-evidence-event.schema.json" <<'PY' || fail "1: a written line fails independent schema validation"
import json, sys, jsonschema
schema = json.load(open(sys.argv[2]))
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(lines) == 9, len(lines)
for l in lines: jsonschema.validate(l, schema)
types = [l["event_type"] for l in lines]
for t in ("slice_dispatched","arbiter_iteration_started","arbiter_iteration_finished",
          "codex_round_started","codex_round_finished","slice_green","run_completed"):
    assert t in types, t
assert all(l["run_id"]=="r-1" and l["slug"]=="demo" for l in lines)
PY

# --- 3) append-only: the earlier half is byte-identical inside the final file
head -c "${#HALF}" "$JL" > "$T/head.actual"; printf '%s' "$HALF" > "$T/head.expected"
cmp -s "$T/head.actual" "$T/head.expected" || fail "3: earlier lines were rewritten (append-only broken)"

# --- 2b) running -> complete at finalize
OLD_UPD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run"]["updated_at"])' "$RE")
python3 "$E" update-run "$EV" --status complete --run-id r-1 --slug demo --feature-tip bbb --dirty-at-end false >/dev/null || fail "2b: update-run -> complete failed"
python3 - "$RE" "$OLD_UPD" <<'PY' || fail "2b: complete/updated_at/feature_tip not recorded"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["run"]["status"]=="complete" and d["run"]["updated_at"]!=sys.argv[2]
assert d["repo"]["feature_tip"]=="bbb" and d["repo"]["dirty_at_end"] is False
PY

# --- 4) fail-closed
N=$(wc -l < "$JL")
AP --event-type made_up_event --actor main --summary x >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "4: unknown event_type accepted (rc=$RC)"
[ "$(wc -l < "$JL")" -eq "$N" ] || fail "4: invalid event still reached events.jsonl"
python3 "$E" append "$EV" --run-id r-OTHER --slug demo --event-type slice_green --actor main --summary x >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "4: run_id mismatch vs run-evidence.json accepted (rc=$RC)"
[ "$(wc -l < "$JL")" -eq "$N" ] || fail "4: mismatched event still reached events.jsonl"
python3 "$E" update-run "$EV" --status running --run-id r-OTHER >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "4: update-run with wrong --run-id accepted (rc=$RC)"
python3 "$E" update-run "$EV" --status not-a-status --run-id r-1 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "4: invalid status accepted (rc=$RC)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["run"]["status"]=="complete"' "$RE" || fail "4: a refused update still changed the file"
python3 "$E" update-run "$T/.parallax/other/evidence" --status running >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "4: update-run silently created a missing run-evidence.json (rc=$RC)"

echo "t_evidence_events_run_phase OK"
