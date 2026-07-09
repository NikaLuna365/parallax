#!/usr/bin/env bash
# v0.37.3 F3 — EXECUTES scripts/pre-freeze-budget.py closure semantics. Locks:
#   1. a schema-valid verifier PASS round writes closure.status=independent-pass
#      (round/artifact/provider/closed_by all machine-derived) and check reports it;
#   2. a CONCERNS round at the budget cap stays decision=checkpoint with closure open —
#      the cap itself never closes anything;
#   3. an orchestrator-style self-attestation cannot certify: (a) a bolted-on
#      `all_resolved: true` field is schema-rejected; (b) a hand-flipped
#      `independent-pass` with no matching pass round is caught by the semantic
#      cross-check; (c) a closed_by other than the machine constant is schema-rejected;
#      (d) a doctored `open` hiding a real pass round is also caught (both directions);
#   4. a human grant-one authorizes exactly one more round and leaves closure open —
#      only that round's own pass (if it comes) closes pre-freeze.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; cd "$PLUGIN"
PF(){ python3 scripts/pre-freeze-budget.py "$@" --mode interactive; }   # v0.37.5 5.1: closure semantics exercised on the interactive path; mode binding has its own fixture
fail(){ echo "FAIL: $1"; exit 1; }
python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo "t_pre_freeze_closure SKIP (jsonschema not installed — the gate itself fails closed without it)"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp assets/codex/codex.toml.example "$T/codex.toml"
printf 'candidate spec\n'      > "$T/spec.md"
printf 'candidate slices\n'    > "$T/slices.md"
printf 'candidate validation\n'> "$T/validation.md"
printf '{"slug":"demo","slices":["S1"]}\n' > "$T/slices.lock"
CF=(--contract-file "$T/spec.md" --contract-file "$T/slices.md" --contract-file "$T/validation.md" --contract-file "$T/slices.lock")
CONCERNS='{"verdict":"concerns","findings":[{"severity":"high","kind":"spec-gap","where":"B1","detail":"observable divergence"}]}'
PASS='{"verdict":"pass","findings":[]}'

# --- 1) pass round -> independent-pass, machine-derived fields, check reports it
A="$T/a"; mkdir -p "$A"; SA="$A/pre-freeze-state.json"
printf '%s\n' "$CONCERNS" > "$A/r1.json"; printf '%s\n' "$PASS" > "$A/r2.json"
PF record "$SA" "$A/r1.json" --policy "$T/codex.toml" --slug demo --provider codex "${CF[@]}" >/dev/null || fail "1: round1 concerns record failed"
python3 - "$SA" <<'PY' || fail "1: closure not open after a concerns round"
import json,sys; s=json.load(open(sys.argv[1])); assert s["closure"]=={"status":"open"}, s["closure"]
PY
OUT=$(PF record "$SA" "$A/r2.json" --policy "$T/codex.toml" --slug demo --provider codex "${CF[@]}") || fail "1: round2 pass record failed"
echo "$OUT" | grep -qF '"closure": "independent-pass"' || fail "1: record(pass) did not report independent-pass: $OUT"
python3 - "$SA" <<'PY' || fail "1: closure fields not machine-derived"
import json,sys
c=json.load(open(sys.argv[1]))["closure"]
assert c["status"]=="independent-pass" and c["round"]==2 and c["artifact"]=="pre_freeze.round2.json"
assert c["provider"]=="codex" and c["closed_by"]=="independent-verifier" and c["closed_at"]
PY
CHK=$(PF check "$SA" --policy "$T/codex.toml" --slug demo); CHKRC=$?   # budget is spent (rc=2) — but closure must read independent-pass
echo "$CHK" | grep -qF '"closure": "independent-pass"' || fail "1: check does not surface independent-pass (rc=$CHKRC): $CHK"

# --- 2) concerns at the cap -> checkpoint, closure open (the cap never closes)
B="$T/b"; mkdir -p "$B"; SB="$B/pre-freeze-state.json"
printf '%s\n' "$CONCERNS" > "$B/r.json"
PF record "$SB" "$B/r.json" --policy "$T/codex.toml" --slug demo --provider codex "${CF[@]}" >/dev/null || fail "2: round1 record failed"
PF record "$SB" "$B/r.json" --policy "$T/codex.toml" --slug demo --provider codex "${CF[@]}" >/tmp/parallax_pfc2; RC=$?
[ "$RC" -eq 2 ] || fail "2: concerns at cap did not checkpoint (rc=$RC)"
PF check "$SB" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc3; RC=$?
[ "$RC" -eq 2 ] || fail "2: check at cap did not checkpoint (rc=$RC)"
grep -qF '"closure": "open"' /tmp/parallax_pfc3 || fail "2: closure not open at the cap: $(cat /tmp/parallax_pfc3)"

# --- 3a) a bolted-on all_resolved:true is schema-rejected (additionalProperties:false)
python3 - "$SB" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["all_resolved"]=True; json.dump(s,open(p,"w"))
PY
PF check "$SB" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc4; RC=$?
[ "$RC" -eq 2 ] || fail "3a: all_resolved:true state was accepted (rc=$RC)"
grep -qiF 'schema validation failed' /tmp/parallax_pfc4 || fail "3a: not rejected by schema: $(cat /tmp/parallax_pfc4)"
python3 - "$SB" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s.pop("all_resolved"); json.dump(s,open(p,"w"))
PY

# --- 3b) a hand-flipped independent-pass with no matching pass round is caught
python3 - "$SB" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["closure"]={"status":"independent-pass","round":2,"artifact":"pre_freeze.round2.json",
              "provider":"codex","closed_at":"2026-07-02T00:00:00Z","closed_by":"independent-verifier"}
json.dump(s,open(p,"w"))
PY
PF check "$SB" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc5; RC=$?
[ "$RC" -eq 2 ] || fail "3b: hand-flipped independent-pass was accepted (rc=$RC)"
grep -qF 'verdict is not pass' /tmp/parallax_pfc5 || fail "3b: wrong rejection reason: $(cat /tmp/parallax_pfc5)"

# --- 3c) closed_by anything but the machine constant is schema-rejected
python3 - "$SB" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["closure"]={"status":"independent-pass","round":2,"artifact":"pre_freeze.round2.json",
              "provider":"codex","closed_at":"2026-07-02T00:00:00Z","closed_by":"orchestrator"}
json.dump(s,open(p,"w"))
PY
PF check "$SB" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc6; RC=$?
[ "$RC" -eq 2 ] || fail "3c: closed_by=orchestrator was accepted (rc=$RC)"
grep -qiF 'schema validation failed' /tmp/parallax_pfc6 || fail "3c: not rejected by schema: $(cat /tmp/parallax_pfc6)"
python3 - "$SB" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["closure"]={"status":"open"}; json.dump(s,open(p,"w"))
PY

# --- 3d) the reverse doctoring — an 'open' closure hiding a real terminal pass — is caught
python3 - "$SA" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["closure"]={"status":"open"}; json.dump(s,open(p,"w"))
PY
PF check "$SA" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc7; RC=$?
[ "$RC" -eq 2 ] || fail "3d: doctored open over a pass round was accepted (rc=$RC)"
grep -qF 'not machine-written as independent-pass' /tmp/parallax_pfc7 || fail "3d: wrong rejection reason: $(cat /tmp/parallax_pfc7)"

# --- 4) grant-one authorizes ONE more round; closure stays open until that round's own pass
TOKEN=$(python3 -c 'import json; print(json.load(open("/tmp/parallax_pfc3"))["grant_token"])')
PF grant-one "$SB" --policy "$T/codex.toml" --slug demo --token "$TOKEN" >/dev/null || fail "4: valid grant refused"
PF check "$SB" --policy "$T/codex.toml" --slug demo >/tmp/parallax_pfc8 || fail "4: granted round not runnable"
grep -qF '"closure": "open"' /tmp/parallax_pfc8 || fail "4: the grant itself changed closure: $(cat /tmp/parallax_pfc8)"
printf '%s\n' "$PASS" > "$B/r3.json"
OUT=$(PF record "$SB" "$B/r3.json" --policy "$T/codex.toml" --slug demo --provider codex "${CF[@]}") || fail "4: granted round record failed"
echo "$OUT" | grep -qF '"closure": "independent-pass"' || fail "4: the granted round's own pass did not close: $OUT"

echo "t_pre_freeze_closure OK"
