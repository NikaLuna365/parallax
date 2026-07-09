#!/usr/bin/env bash
# v0.37.5 6.2 / TRIAGE gate C1 — EXECUTES feature-sweep.py's production-path consumer rule,
# replaying the RUN2 latent case: a 19MB media-safety seam was "proven" only by a
# test-file-local re-implementation of the production normalizer (tests/test_integration.py
# _normalize_channel_post), never by the real consumer. Locks:
#   C1a. a required_consumer whose only match lives in test files -> dead_shared_field
#        violation naming the test-only hits (a test-authored duplicate is NOT a consumer);
#   C1b. the same field consumed by a real PRODUCTION file -> clean;
#   C1c. production_only:false deliberately accepts a test-side consumer (recorded opt-out);
#   C1d. no consumer anywhere still violates (the original v0.37 dead-seam rule intact).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; FS="$PLUGIN/scripts/feature-sweep.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

mkrepo(){ # $1=dir  $2=consumer-mode: none|test|prod
  R="$T/$1"; mkdir -p "$R/src" "$R/tests" "$R/.parallax/demo"
  cat > "$R/src/bot.py" <<'P'
def normalize_channel_post(update):
    return {"photo_size": max(p["file_size"] for p in update["photo"])}
P
  [ "$2" = test ] && cat > "$R/tests/test_integration.py" <<'P'
def _normalize_channel_post(update):   # test-authored DUPLICATE of the production normalizer
    return {"photo_size": max(p["file_size"] for p in update["photo"])}
def test_gate(): assert _normalize_channel_post({"photo":[{"file_size":1}]})["photo_size"] == 1
P
  [ "$2" = prod ] && cat > "$R/src/engine.py" <<'P'
from bot import normalize_channel_post          # the REAL consumer path
def gate(update): return normalize_channel_post(update)["photo_size"] <= 19*1024*1024
P
  echo "$R"
}
manifest(){ # $1=repo $2=extra-json-fields
  cat > "$1/.parallax/demo/invariants.json" <<J
{"schema_version":"parallax-feature-invariants-v1","slug":"demo",
 "required_consumers":[{"id":"RC-1","field":"normalize_channel_post",
   "producer_paths":["src/bot.py"],"consumer_paths":["src/engine.py","tests/**"],
   "reason":"the 19MB media gate must consume the production normalizer"$2}]}
J
}

# --- C1a) consumer ONLY in tests -> violation, test-only hits named
R=$(mkrepo a test); manifest "$R" ""
OUT=$(python3 "$FS" --repo "$R" --slug demo); RC=$?
[ "$RC" -eq 2 ] || fail "C1a: test-authored duplicate accepted as a consumer (rc=$RC): $OUT"
echo "$OUT" | grep -qF 'test-authored' || fail "C1a: violation does not name the duplicate rule: $OUT"
echo "$OUT" | grep -qF 'tests/test_integration.py' || fail "C1a: test-only hit not listed: $OUT"

# --- C1b) real production consumer -> clean
R=$(mkrepo b prod); manifest "$R" ""
python3 "$FS" --repo "$R" --slug demo >/tmp/parallax_ps2; RC=$?
[ "$RC" -eq 0 ] || fail "C1b: production consumer rejected (rc=$RC): $(cat /tmp/parallax_ps2)"

# --- C1c) deliberate opt-out: production_only=false accepts the test-side consumer
R=$(mkrepo c test); manifest "$R" ',"production_only":false'
python3 "$FS" --repo "$R" --slug demo >/tmp/parallax_ps3; RC=$?
[ "$RC" -eq 0 ] || fail "C1c: recorded opt-out did not apply (rc=$RC): $(cat /tmp/parallax_ps3)"

# --- C1d) no consumer anywhere -> still a dead seam (original rule intact)
R=$(mkrepo d none); manifest "$R" ""
python3 "$FS" --repo "$R" --slug demo >/tmp/parallax_ps4; RC=$?
[ "$RC" -eq 2 ] || fail "C1d: dead seam not caught (rc=$RC)"
grep -qF 'no consumer at all' /tmp/parallax_ps4 || fail "C1d: wrong detail: $(cat /tmp/parallax_ps4)"

echo "t_production_seam OK"
