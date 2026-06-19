#!/usr/bin/env bash
# verify-codex.sh — one-shot smoke test for the cross-model verifier wiring.
# Run this ON YOUR MACHINE (where `codex` is installed) to confirm the exact
# CLI flags + structured-output work against your installed codex version.
# This is the ONE thing the plugin's mechanical harness can't check remotely.
#
# Usage:
#   ./verify-codex.sh [path/to/verdict.schema.json]
# Defaults to the schema shipped in the plugin if you pass its path, else looks
# next to this script.

set -uo pipefail

SCHEMA="${1:-./assets/codex/verdict.schema.json}"
TOML="${TDD_CODEX_TOML:-.tdd/codex.toml}"

echo "== codex verifier smoke test =="

# 1. codex present?
if ! command -v codex >/dev/null 2>&1; then
  echo "✗ codex CLI not found on PATH. Install it / fix PATH, then re-run."
  echo "  (In autonomous mode this means on_missing applies — default 'refuse'.)"
  exit 1
fi
echo "✓ codex found: $(command -v codex)"

# 2. model pinned in config (not hardcoded)?
MODEL=""
[ -f "$TOML" ] && MODEL=$(grep -E '^\s*model' "$TOML" | sed 's/.*=\s*"\(.*\)".*/\1/')
if [ -z "$MODEL" ]; then
  echo "! no model in $TOML — falling back to a default for this test; set one before real runs."
  MODEL="gpt-5.5"
fi
echo "✓ model from config: $MODEL"

[ -f "$SCHEMA" ] || { echo "✗ schema not found at $SCHEMA (pass the plugin's assets/codex/verdict.schema.json)"; exit 1; }

# 3. real, read-only, schema-constrained invocation on a trivial review.
#    If your codex version names a flag differently, this is where you'll see it —
#    adjust the flags here AND in skills/role-codex-judge + agents/codex-judge.
OUT=$(codex exec \
        --model "$MODEL" \
        --sandbox read-only \
        --output-schema "$SCHEMA" \
        "You are a post-green verifier. The slice spec says quote()==25 and the impl returns 25 with a matching test. Reply strictly as the schema: verdict 'pass' with empty findings." \
      2>/tmp/codex.err)
RC=$?

if [ $RC -ne 0 ]; then
  echo "✗ codex exec failed (rc=$RC). Stderr:"; sed 's/^/    /' /tmp/codex.err
  echo "  → Most likely a flag-name mismatch for your codex version. Check: --sandbox, --output-schema, exec subcommand."
  exit 1
fi
echo "✓ codex exec ran read-only with --output-schema"

# 4. output is valid JSON matching the schema?
OUT_JSON="$OUT" python3 - "$SCHEMA" <<'PY'
import json, os, sys
data = json.loads(os.environ["OUT_JSON"])   # via env var, NOT stdin — stdin here IS the heredoc program
try:
    import jsonschema
except Exception:
    assert data.get("verdict") in ("pass","concerns"), "verdict field wrong/missing"
    print("✓ output is valid JSON with a verdict (install `jsonschema` for full schema check)")
    sys.exit(0)
jsonschema.validate(data, json.load(open(sys.argv[1])))
print(f"✓ output validates against schema — verdict={data['verdict']}, findings={len(data['findings'])}")
PY
RC=$?
[ $RC -eq 0 ] && echo "== PASS: the cross-model verifier wiring works on this machine ==" \
             || { echo "✗ output did not match the schema; see above."; exit 1; }
