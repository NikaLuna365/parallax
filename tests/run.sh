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

echo "[no_overclaims]  (locks P5: blindness is honest — removal + discipline, not 'provably/physically cannot')"
if grep -rEn "provably (blind|tested)|physically (lacks|has no|does not contain|hide)" skills/ agents/ commands/ >/dev/null 2>&1; then
  no "blindness overclaim phrases still present"; grep -rEn "provably (blind|tested)|physically (lacks|has no|does not contain|hide)" skills/ agents/ commands/ | sed 's/^/      /'
else ok "no blindness overclaims (honest 'removed from working tree' wording)"; fi
grep -q "Reaching the hidden side" skills/tdd-core/SKILL.md && ok "tdd-core has the no-peeking-via-git anti-cheat rule" || no "missing the git-peek anti-cheat rule"

echo "[runstate_lock]  (locks P4: resume state completeness + atomic mutual exclusion)"
python3 - <<'PY' && ok "run-state schema accepts SHAs/verdict/wave/lock; round-trips" || no "run-state schema round-trip"
import json
try: import jsonschema
except ImportError:
    import sys; print("   (jsonschema not installed — basic check only)");
schema=json.load(open('assets/run-state.schema.json'))
sp=schema['properties']['slices']['items']['properties']
for k in ('code_tip','test_tip','wave','arbiter_verdict','verified_diff'): assert k in sp, f"slice missing {k}"
assert 'lock' in schema['properties'], "no run-level lock"
st={"slug":"d","epic":"feature/e","base_tip":"abc","status":"paused-on-limit",
    "slices":[{"id":"S1","status":"in_progress","code_tip":"aaa","test_tip":"bbb","wave":0,"arbiter_verdict":None,"verified_diff":None}],
    "lock":{"holder":"run1","acquired_at":"2026-06-19T10:00:00Z","expires_at":"2026-06-19T11:00:00Z"},
    "updated_at":"2026-06-19T10:00:00Z"}
try:
    import jsonschema; jsonschema.validate(st, schema)
except ImportError: pass
PY
LT=$(mktemp -d); ( cd "$LT" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  A=$(git rev-parse HEAD); Z=0000000000000000000000000000000000000000
  git update-ref refs/tdd/lock/d "$A" "$Z" 2>/dev/null && r1=win || r1=lose      # create-if-absent
  git update-ref refs/tdd/lock/d "$A" "$Z" 2>/dev/null && r2=win || r2=lose      # second must fail (exists)
  [ "$r1" = win ] && [ "$r2" = lose ] ) \
  && ok "atomic lock: two concurrent CAS acquires -> exactly one wins (no double-run)" || no "lock mutual exclusion"
rm -rf "$LT"

echo "[mode_branches]  (locks P6: every config mode has a contract branch in run.md)"
miss=""; for m in split panel sole; do grep -q "\*\*\`$m\`\*\*" commands/run.md || miss="$miss $m"; done
[ -z "$miss" ] && ok "run.md has a branch for every verifier mode (split / panel / sole)" || no "run.md missing mode branch:$miss"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
