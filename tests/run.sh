#!/usr/bin/env bash
# Self-test harness for the tdd plugin. Run from anywhere: `bash tests/run.sh`.
# Locks the invariants that manual audits kept finding. Exit nonzero on any failure.
# Deps: python3 (+ optional `jsonschema` for full schema validation), git.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> plugin root
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "== tdd plugin self-tests =="

echo "[toml_semantics]  (locks P2: root scalars must not be swallowed by a [table])"
python3 - <<'PY' && ok "config: enabled/points/mode/on_missing/timeout_s at root; tables hold only their keys" || no "TOML semantics"
import tomllib
d=tomllib.load(open('assets/codex/codex.toml.example','rb'))
for k in ('enabled','points','mode','on_missing','timeout_s'):
    assert k in d, f"root key '{k}' missing (likely swallowed by a [table])"
assert set(d['primary'])  <= {'provider','form','model'}, d['primary']
assert set(d['fallback']) <= {'provider','form','model'}, d['fallback']
assert 'interval_minutes' in d['retry']
assert d['notify']['enabled'] is False and d['notify']['token_env'] and d['notify']['chat_id_env']
PY

echo "[schemas_valid]"
python3 - <<'PY' && ok "all JSON schemas + manifests valid" || no "invalid JSON"
import json,glob
for j in glob.glob('assets/**/*.json',recursive=True)+['.claude-plugin/plugin.json','.claude-plugin/marketplace.json']:
    d=json.load(open(j))
    if j.endswith('schema.json'): assert ('properties' in d) or ('type' in d), f"{j}: not a schema"
PY

echo "[refs_integrity]"
python3 - <<'PY' && ok "frontmatter + agent skills + run.md sections + assets all resolve" || no "broken refs"
import glob,os,re
skills={os.path.basename(os.path.dirname(p)) for p in glob.glob('skills/*/SKILL.md')}
for p in glob.glob('commands/*.md')+glob.glob('agents/*.md')+glob.glob('skills/*/SKILL.md'):
    t=open(p).read(); assert t.startswith('---'), f"{p}: no frontmatter"
    fmt=t[3:t.find('---',3)]
    assert re.search(r'(?m)^name:\s*\S',fmt) and re.search(r'(?m)^description:\s*\S',fmt), f"{p}: name/description"
for p in glob.glob('agents/*.md'):
    fmt=open(p).read(); fmt=fmt[3:fmt.find('---',3)]
    m=re.search(r'(?ms)^skills:\s*\n((?:[ \t]*-[ \t]*\S+\s*\n?)+)',fmt)
    if m:
        for s in re.findall(r'-[ \t]*(\S+)',m.group(1)):
            assert s in skills, f"{p}: skills ref '{s}' has no skills/{s}/SKILL.md"
run=open('commands/run.md').read()
for sec in ['## Autonomous & parallel execution','## Limits, checkpointing & resume','## Notifications']:
    assert sec in run, f"run.md missing section: {sec}"
for a in ['assets/codex/verdict.schema.json','assets/codex/spec-adversary.schema.json','assets/run-state.schema.json']:
    assert os.path.exists(a), f"missing asset {a}"
PY

echo "[git_assembly_correctness]  (locks P1: slice integration is assembly, not merge)"
bash tests/t_assembly.sh >/tmp/asm.out 2>&1 && ok "assembly preserves files; blindfold-merge loses them" || { no "assembly correctness"; sed 's/^/      /' /tmp/asm.out; }
grep -q "by assembly, NOT merge" commands/run.md && ok "run.md: slice integration documented as assembly, not merge" || no "run.md slice integration still uses merge"

echo "[smoke_selftest]  (locks P3: verdict validation works, no heredoc/pipe bug)"
GOOD='{"verdict":"pass","findings":[]}'; BAD='{"verdict":"maybe"}'
OUT_JSON="$GOOD" python3 - assets/codex/verdict.schema.json <<'PY' && ok "validation accepts a valid verdict (JSON via env, not stdin)" || no "validation rejected a valid verdict"
import json,os,sys
d=json.loads(os.environ["OUT_JSON"])
try:
    import jsonschema; jsonschema.validate(d,json.load(open(sys.argv[1])))
except ImportError:
    assert d.get("verdict") in ("pass","concerns")
PY
if OUT_JSON="$BAD" python3 - assets/codex/verdict.schema.json <<'PY' >/dev/null 2>&1
import json,os,sys,jsonschema
jsonschema.validate(json.loads(os.environ["OUT_JSON"]),json.load(open(sys.argv[1])))
PY
then no "validation ACCEPTED an invalid verdict"; else ok "validation rejects an invalid verdict"; fi
if ls tests/verify-*.sh >/dev/null 2>&1; then
  if grep -REn 'echo[^|]*\|[[:space:]]*python3[[:space:]]+-[^<]*<<' tests/verify-*.sh >/dev/null 2>&1; then
    no "verify-*.sh reintroduced the echo|python3 -<<heredoc bug"
  else ok "verify-*.sh free of the heredoc/pipe bug (read JSON via env var)"; fi
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
