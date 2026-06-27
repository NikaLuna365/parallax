#!/usr/bin/env bash
# v0.37 P0.3 — EXECUTES scripts/feature-sweep.py. A tree whose per-slice unit tests all pass but
# which still violates a declared whole-feature invariant (a PII field serialized across files) is
# caught; removing the leak passes; a mock-only I/O slice with neither an integration check nor a
# stamp is caught and the explicit stamp clears it; a missing manifest fails closed.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; S="$PLUGIN/scripts/feature-sweep.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

R="$T/repo"; mkdir -p "$R/src/api" "$R/src/model" "$R/tests" "$R/.parallax/demo/stamps"
cat > "$R/src/model/user.py" <<'EOF'
class User:
    def __init__(self, name, ssn):
        self.name = name
        self.ssn = ssn   # PII
EOF
cat > "$R/src/api/serialize.py" <<'EOF'
def to_json(u):
    return {"name": u.name, "ssn": u.ssn}   # forbidden: PII leaked to the wire
EOF
echo 'def test_user(): assert True' > "$R/tests/test_user.py"
cat > "$R/.parallax/demo/invariants.json" <<'EOF'
{ "schema_version":"parallax-feature-invariants-v1","slug":"demo",
  "forbidden_patterns":[{"id":"PII1","pattern":"[\"']ssn[\"']\\s*:","paths":["src/api/*.py"],"reason":"SSN must never be serialized to a response"}] }
EOF
python3 "$S" --repo "$R" --slug demo >/dev/null; [ $? -eq 2 ] || fail "PII serialization across files not caught"

# remove the leak -> clean (exit 0)
cat > "$R/src/api/serialize.py" <<'EOF'
def to_json(u):
    return {"name": u.name}
EOF
python3 "$S" --repo "$R" --slug demo >/dev/null; [ $? -eq 0 ] || fail "clean tree not accepted"

# mock-only I/O slice with neither integration check nor stamp -> violation (exit 2)
cat > "$R/.parallax/demo/invariants.json" <<'EOF'
{ "schema_version":"parallax-feature-invariants-v1","slug":"demo",
  "mock_only_slices":[{"slice_id":"S3","integration_glob":["tests/integration/*.py"],"stamp":".parallax/demo/stamps/S3.mock-only"}] }
EOF
python3 "$S" --repo "$R" --slug demo >/dev/null; [ $? -eq 2 ] || fail "mock-only slice without stamp/integration not caught"
# the explicit 'externals mocked -> integration unverified' stamp clears it -> pass (exit 0)
touch "$R/.parallax/demo/stamps/S3.mock-only"
python3 "$S" --repo "$R" --slug demo >/dev/null; [ $? -eq 0 ] || fail "mock-only stamp not honoured"

# missing manifest -> fail closed (exit 3), never a silent pass
python3 "$S" --repo "$R" --slug other >/dev/null; [ $? -eq 3 ] || fail "missing manifest did not fail closed"

echo "t_feature_sweep OK"
