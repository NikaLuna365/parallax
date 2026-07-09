#!/usr/bin/env bash
# v0.38 §5.4 gate E1 — EXECUTES scripts/evidence-event.py audit-slice. Adopt-critical evidence
# (slice_dispatched + the arbiter receipt) must be emitted even on a hand-driven/degraded path,
# or the step fails closed. Locks:
#   E1a. a slice with slice_dispatched + arbiter_green -> OK (exit 0);
#   E1b. a HAND-DRIVEN slice integrated with NO such evidence -> FLAGGED (exit 2), not silent;
#   E1c. a slice with slice_dispatched but no arbiter receipt -> FLAGGED (exit 2) by default;
#   E1d. --no-require-arbiter relaxes E1c to require only slice_dispatched (exit 0);
#   E1e. slice ids match as WHOLE tokens (S1 must not satisfy S10's requirement).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; EE="$PLUGIN/scripts/evidence-event.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
EV="$T/.parallax/demo/evidence"; mkdir -p "$EV"
ev(){ printf '{"schema_version":"parallax-run-evidence-event-v1","run_id":"r1","slug":"demo","at":"t","event_type":"%s","actor":"%s","summary":"%s","artifact_paths":{}}\n' "$1" "$2" "$3" >> "$EV/events.jsonl"; }

ev slice_dispatched main "S6 dispatched to both blind tracks"
ev arbiter_green arbiter "S6: green"
ev slice_dispatched main "S7 dispatched"          # S7 dispatched but never arbitered (degraded)
ev slice_dispatched main "S10 dispatched to both tracks"
ev arbiter_green arbiter "S10: green"

# E1a — S6 complete
python3 "$EE" audit-slice "$EV" --slice S6 --slug demo >/dev/null || fail "E1a: complete slice flagged"
# E1b — S1 hand-driven, no evidence at all
python3 "$EE" audit-slice "$EV" --slice S1 --slug demo >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "E1b: hand-driven slice with no evidence NOT flagged (rc=$RC)"
# E1c — S7 dispatched but no arbiter receipt
python3 "$EE" audit-slice "$EV" --slice S7 --slug demo >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "E1c: missing arbiter receipt NOT flagged (rc=$RC)"
# E1d — relax arbiter requirement
python3 "$EE" audit-slice "$EV" --slice S7 --slug demo --no-require-arbiter >/dev/null || fail "E1d: --no-require-arbiter still flagged a dispatched slice"
# E1e — whole-token match: S1 must not be satisfied by 'S10' lines
python3 "$EE" audit-slice "$EV" --slice S1 --slug demo --no-require-arbiter >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "E1e: 'S1' wrongly matched an S10 summary (token boundary broken)"

echo "t_evidence_required OK"
