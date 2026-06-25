#!/usr/bin/env bash
# v0.31 P3 — EXECUTES scripts/resolution.py migrate (DESIGN_v0.31_safe_completion.md §15 backward-compat).
# A v0.30 run-state (no feature_id / contract_generation) migrates ONCE into a generation-1 feature-state with a
# fresh feature_id; the run-state is stamped consistently; a re-run is an idempotent no-op (same feature_id, ref
# unchanged); and a missing / structurally-insufficient run-state fails closed (no invented source) — the
# migrated feature is then resolve-ready (can transition to needs-resolution).
# Exit: 0 all behaved, 2 SKIP (no jsonschema), 1 a case wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; RES="$PLUGIN/scripts/resolution.py"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
SLUG=demo; OID="$(printf 'd%.0s' $(seq 1 40))"; H="$(printf 'a%.0s' $(seq 1 64))"
ST="$TMP/feature-state.json"; RS="$TMP/run-state.json"

# --- a v0.30 run-state: NO feature_id, NO contract_generation ---
python3 - "$RS" <<'PY'
import json,sys
json.dump({"run_id":"RUN1","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":"complete",
  "verified_tree":"e"*40,"slices":[{"id":"S1","status":"integrated"}],"integrated":["S1"],"updated_at":"t"},
  open(sys.argv[1],"w"))
PY

# --- migrate once ---
OUT=$(python3 "$RES" migrate "$ST" --slug "$SLUG" --run-state "$RS" --base-oid "$OID" --tip-oid "$OID" --contract-hash "$H") \
  || fail "migrate exited non-zero: $OUT"
echo "$OUT" | grep -q '"decision": "migrated"' || fail "first migrate did not report 'migrated': $OUT"
FID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['feature_id'])" "$ST")
[ -n "$FID" ] || fail "no feature_id assigned"
# feature-state is a valid generation-1 record
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['generation']==1 and d['slug']=='demo' and d['parent_run_id'] is None and d['resolution_chain']==[] and d['active_run_id']=='RUN1' and d['status']=='complete', d" "$ST" \
  || fail "migrated feature-state is not a clean generation-1 record"
# the run-state was stamped consistently
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('contract_generation')==1 and d.get('feature_id')==sys.argv[2], d" "$RS" "$FID" \
  || fail "run-state not stamped with contract_generation=1 + matching feature_id"

# --- migrate again: idempotent no-op, same feature_id, feature-state unchanged ---
BEFORE=$(cat "$ST")
OUT2=$(python3 "$RES" migrate "$ST" --slug "$SLUG" --run-state "$RS" --base-oid "$OID" --tip-oid "$OID" --contract-hash "$H") \
  || fail "idempotent re-run exited non-zero: $OUT2"
echo "$OUT2" | grep -q '"decision": "already-migrated"' || fail "re-run was not a no-op: $OUT2"
FID2=$(echo "$OUT2" | python3 -c "import json,sys;print(json.load(sys.stdin)['feature_id'])")
[ "$FID2" = "$FID" ] || fail "feature_id changed on re-run ($FID -> $FID2)"
[ "$(cat "$ST")" = "$BEFORE" ] || fail "idempotent re-run mutated the feature-state"

# --- the migrated feature is resolve-ready: it can enter the resolution lifecycle ---
python3 "$RES" transition "$ST" --slug "$SLUG" --to needs-resolution >/dev/null 2>&1 \
  && fail "a 'complete' migrated feature should not transition straight to needs-resolution" || true
# a running v0.30 run migrates to a running feature that CAN park for resolution
RS2="$TMP/run2.json"; ST2="$TMP/fs2.json"
python3 - "$RS2" <<'PY'
import json,sys
json.dump({"run_id":"RUN9","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":"running",
  "lock":{"holder":"RUN9","acquired_at":"t","expires_at":"t2"},"slices":[{"id":"S1","status":"pending"}],"updated_at":"t"},
  open(sys.argv[1],"w"))
PY
python3 "$RES" migrate "$ST2" --slug "$SLUG" --run-state "$RS2" --base-oid "$OID" --tip-oid "$OID" --contract-hash "$H" >/dev/null \
  || fail "migrating a running v0.30 run failed"
python3 "$RES" transition "$ST2" --slug "$SLUG" --to needs-resolution >/dev/null \
  || fail "a migrated running feature could not transition to needs-resolution (not resolve-ready)"

# --- fail-closed: no run-state to migrate -> escalate, never invent one ---
rc=0; python3 "$RES" migrate "$TMP/none.json" --slug "$SLUG" --run-state "$TMP/missing.json" --base-oid "$OID" --tip-oid "$OID" --contract-hash "$H" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a missing run-state should fail closed with exit 2 (got $rc)"
[ -f "$TMP/none.json" ] && fail "fail-closed migrate must not write a feature-state"

echo "t_resolution_migration OK (v0.30 run-state -> gen-1 feature-state; run-state stamped; idempotent; resolve-ready; fail-closed on a missing source)"
