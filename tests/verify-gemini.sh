#!/usr/bin/env bash
# verify-gemini.sh — one-shot smoke test for the Gemini fallback provider.
# Run this ON YOUR MACHINE (where the `gemini` CLI is installed & signed in).
# Unlike Codex, the Gemini CLI has NO custom --output-schema, so the judge embeds
# the schema in the prompt and validates the returned JSON itself. This script does
# exactly that, so it confirms the real flags + JSON round-trip on your version.
#
# Usage:  ./verify-gemini.sh [path/to/verdict.schema.json]

set -uo pipefail
SCHEMA="${1:-./assets/codex/verdict.schema.json}"
TOML="${TDD_CODEX_TOML:-.tdd/codex.toml}"

echo "== gemini fallback smoke test =="

command -v gemini >/dev/null 2>&1 || { echo "✗ gemini CLI not found on PATH. Install / sign in, then re-run."; exit 1; }
echo "✓ gemini found: $(command -v gemini)"

# model from [fallback] in config, else a sensible default to confirm
MODEL=$(awk '/^\[fallback\]/{f=1} f&&/^model/{gsub(/.*= *"|".*/,"");print;exit}' "$TOML" 2>/dev/null)
[ -z "$MODEL" ] && MODEL="gemini-3-pro"
echo "✓ model: $MODEL  (from [fallback] in $TOML, or default)"

[ -f "$SCHEMA" ] || { echo "✗ schema not found at $SCHEMA"; exit 1; }
SCHEMA_JSON=$(cat "$SCHEMA")

# Embed the schema in the prompt (Gemini has no --output-schema) and ask for JSON-only.
PROMPT="You are a post-green verifier. The slice spec says quote()==25 and the impl returns 25 with a matching test.
Reply with ONLY a JSON object (no prose, no markdown fences) matching this JSON Schema:
$SCHEMA_JSON
For this trivial pass case, return {\"verdict\":\"pass\",\"findings\":[]}."

OUT=$(gemini -p "$PROMPT" --model "$MODEL" --output-format json 2>/tmp/gemini.err)
RC=$?
if [ $RC -ne 0 ]; then
  echo "✗ gemini exec failed (rc=$RC). Stderr:"; sed 's/^/    /' /tmp/gemini.err
  echo "  → Likely a flag-name mismatch for your version (check: -p, --model, --output-format). Adjust here AND in skills/role-codex-judge + agents/codex-judge."
  exit 1
fi
echo "✓ gemini ran headless with --output-format json"

# The model's answer is in the `response` field of the json wrapper; parse + validate it ourselves.
OUT_JSON="$OUT" python3 - "$SCHEMA" <<'PY'
import json, os, sys, re
schema_path=sys.argv[1]
raw=os.environ["OUT_JSON"]   # via env var, NOT stdin — stdin here IS the heredoc program
try:
    wrapper=json.loads(raw)
    text=wrapper.get("response", raw) if isinstance(wrapper, dict) else raw
except Exception:
    text=raw
# strip ```json fences if the model added them
text=re.sub(r"^```(json)?|```$", "", text.strip(), flags=re.MULTILINE).strip()
data=json.loads(text)
try:
    import jsonschema
    jsonschema.validate(data, json.load(open(schema_path)))
    print(f"✓ embedded-schema verdict validates — verdict={data['verdict']}, findings={len(data['findings'])}")
except ImportError:
    assert data.get("verdict") in ("pass","concerns")
    print(f"✓ verdict parsed (verdict={data['verdict']}); install `jsonschema` for full schema check")
PY
[ $? -eq 0 ] && echo "== PASS: Gemini fallback works as a verifier on this machine ==" \
            || { echo "✗ Gemini's output didn't parse/validate as a verdict — tighten the prompt or check the wrapper shape."; exit 1; }
