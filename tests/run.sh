#!/usr/bin/env bash
# Self-test harness for the Parallax plugin. Run from anywhere: `bash tests/run.sh`.
# Where it can, it EXECUTES the real mechanic (git integration, the lock, bash -n on every
# code block, schema validation) rather than grepping for a string — grep gave false
# confidence in earlier versions. LLM-orchestration semantics (mode judgments, timeouts)
# are NOT unit-tested here; those are for integration runs / the Ralphex benchmark.
# Deps: python3 (+ optional jsonschema), git.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "== Parallax plugin self-tests =="

echo "[toml_semantics]"
python3 - <<'PY' && ok "config: root scalars at root; tables hold only their keys" || no "TOML semantics"
import tomllib
d=tomllib.load(open('assets/codex/codex.toml.example','rb'))
for k in ('enabled','points','mode','on_missing','timeout_s'): assert k in d, f"root key '{k}' swallowed by a [table]"
assert set(d['primary'])<= {'provider','form','model'} and set(d['fallback'])<= {'provider','form','model'}
assert d['git']['branch_prefix']=="feature/" and d['notify']['enabled'] is False
PY

echo "[schemas_valid]"
python3 - <<'PY' && ok "all JSON schemas + manifests valid" || no "invalid JSON"
import json,glob
for j in glob.glob('assets/**/*.json',recursive=True)+['.claude-plugin/plugin.json','.claude-plugin/marketplace.json']:
    d=json.load(open(j))
    if j.endswith('schema.json'): assert ('properties' in d) or ('type' in d), j
PY

echo "[refs_integrity]"
python3 - <<'PY' && ok "frontmatter + agent skills + run.md sections + assets resolve" || no "broken refs"
import glob,os,re
sk={os.path.basename(os.path.dirname(p)) for p in glob.glob('skills/*/SKILL.md')}
for p in glob.glob('commands/*.md')+glob.glob('agents/*.md')+glob.glob('skills/*/SKILL.md'):
    t=open(p).read(); assert t.startswith('---'),p; f=t[3:t.find('---',3)]
    assert re.search(r'(?m)^name:\s*\S',f) and re.search(r'(?m)^description:\s*\S',f),p
for p in glob.glob('agents/*.md'):
    f=open(p).read(); f=f[3:f.find('---',3)]; m=re.search(r'(?ms)^skills:\s*\n((?:[ \t]*-[ \t]*\S+\s*\n?)+)',f)
    if m:
        for s in re.findall(r'-[ \t]*(\S+)',m.group(1)): assert s in sk,f"{p}: bad skills ref {s}"
run=open('commands/run.md').read()
for s in ['## Autonomous & parallel execution','## Limits, checkpointing & resume','## Notifications']: assert s in run,s
for a in ['assets/codex/verdict.schema.json','assets/codex/spec-adversary.schema.json','assets/run-state.schema.json']: assert os.path.exists(a),a
PY

echo "[shell_syntax]  (EXECUTES bash -n on every fenced bash block in run.md — locks P5)"
python3 - <<'PY'
import re
t=open('commands/run.md').read(); n=0
for m in re.findall(r'```bash\n(.*?)```', t, re.S):
    s=re.sub(r'<[^>\n]*>','PH',m)           # neutralize <placeholders>
    open(f'/tmp/parallax_blk{n}.sh','w').write(s); n+=1
open('/tmp/parallax_nblk','w').write(str(n))
PY
nblk=$(cat /tmp/parallax_nblk); bad=0
for i in $(seq 0 $((nblk-1))); do bash -n "/tmp/parallax_blk$i.sh" 2>/tmp/parallax_syn || { bad=1; echo "      block $i: $(cat /tmp/parallax_syn)"; }; done
[ "$bad" = 0 ] && ok "all $nblk run.md bash blocks pass bash -n" || no "a run.md bash block has a shell syntax error"

echo "[integration]  (EXECUTES the parallel wave — locks P0 #1 data-loss + #2 branch prefix)"
bash tests/t_assembly.sh feature/ >/tmp/parallax_int1 2>&1 && ok "per-slice diff integration preserves a 2-slice wave (prefix feature/)" || { no "integration (feature/)"; sed 's/^/      /' /tmp/parallax_int1; }
bash tests/t_assembly.sh claude/  >/tmp/parallax_int2 2>&1 && ok "same works under a non-default prefix (claude/ — cloud routine)" || { no "integration (claude/)"; sed 's/^/      /' /tmp/parallax_int2; }
grep -q "per-slice DIFF" commands/run.md && ok "run.md documents per-slice DIFF integration (not mirror)" || no "run.md still documents mirror integration"

echo "[lock]  (EXECUTES the documented lock — locks P1 #3)"
bash tests/t_lock.sh >/tmp/parallax_lock 2>&1 && ok "lock: documented command works + cross-clone push yields one winner" || { no "lock"; sed 's/^/      /' /tmp/parallax_lock; }

echo "[runstate_schema]  (EXECUTES validation — locks P1 #4 exact-resume completeness)"
python3 - <<'PY' >/tmp/parallax_rs 2>&1
import json
try: import jsonschema
except ImportError: print("SKIP"); raise SystemExit
s=json.load(open('assets/run-state.schema.json'))
ok_full={"run_id":"r","slug":"d","epic":"e","base_tip":"b","status":"running",
  "slices":[{"id":"S1","status":"green-unverified","arbiter_verdict":"green","verified_diff":"sha1"},
            {"id":"S2","status":"in_progress","code_tip":"aa","test_tip":"bb"}],
  "lock":{"holder":"r","acquired_at":"t","expires_at":"t2"},"updated_at":"t"}
jsonschema.validate(ok_full,s)
bad={"run_id":"r","slug":"d","epic":"e","base_tip":"b","status":"running","slices":[{"id":"S1","status":"green-unverified"}],"updated_at":"t"}
try: jsonschema.validate(bad,s); print("ACCEPTED_BAD")
except Exception: print("OK")
PY
R=$(cat /tmp/parallax_rs)
if [ "$R" = "SKIP" ]; then echo "  · jsonschema not installed — schema-completeness test skipped";
elif [ "$R" = "OK" ]; then ok "schema accepts a complete checkpoint and REJECTS an incomplete green-unverified"; else no "schema accepts incomplete green-unverified ($R)"; fi

echo "[smoke_selftest]  (locks P3)"
G='{"verdict":"pass","findings":[]}'; B='{"verdict":"maybe"}'
OUT_JSON="$G" python3 - assets/codex/verdict.schema.json <<'PY' && ok "validation accepts a valid verdict (JSON via env)" || no "rejected a valid verdict"
import json,os,sys
d=json.loads(os.environ["OUT_JSON"])
try:
    import jsonschema; jsonschema.validate(d,json.load(open(sys.argv[1])))
except ImportError: assert d.get("verdict") in ("pass","concerns")
PY
if OUT_JSON="$B" python3 - assets/codex/verdict.schema.json <<'PY' >/dev/null 2>&1
import json,os,sys,jsonschema; jsonschema.validate(json.loads(os.environ["OUT_JSON"]),json.load(open(sys.argv[1])))
PY
then no "validation ACCEPTED an invalid verdict"; else ok "validation rejects an invalid verdict"; fi
grep -REq 'echo[^|]*\|[[:space:]]*python3[[:space:]]+-[^<]*<<' tests/verify-*.sh 2>/dev/null && no "verify-*.sh reintroduced the heredoc/pipe bug" || ok "verify-*.sh free of the heredoc/pipe bug"

echo "[no_overclaims]  (locks P5 honesty)"
grep -rEn "provably (blind|tested)|physically (lacks|has no|does not contain|hide)" skills/ agents/ commands/ >/dev/null 2>&1 && no "blindness overclaim phrases present" || ok "no blindness overclaims"
grep -q "Reaching the hidden side" skills/parallax-core/SKILL.md && ok "parallax-core has the no-peeking-via-git anti-cheat rule" || no "missing git-peek rule"

echo "[mode_branches]  (presence check — semantics are integration-validated, not unit-tested)"
miss=""; for m in split panel sole; do grep -q "\*\*\`$m\`\*\*" commands/run.md || miss="$miss $m"; done
[ -z "$miss" ] && ok "run.md has a who-judges branch for split / panel / sole" || no "missing mode branch:$miss"
grep -q "for GREEN _and_ RED" commands/run.md && ok "sole judges GREEN and RED (verifier is the judge, not only post-green)" || no "sole still only post-green"

echo "[security_no_secrets]  (locks repo hygiene)"
grep -qE 'sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,}|[0-9]{6,}:[A-Za-z0-9_-]{20,}' assets/codex/codex.toml.example && no "config has a secret-shaped value" || ok "config has no secret-shaped values (only *_env names)"
{ [ -f SECURITY.md ] && grep -q '^\.env$' .gitignore; } && ok "SECURITY.md + .gitignore (.env) present" || no "SECURITY.md/.gitignore missing"

echo "[cloud_setup]  (real install attempts, not commented-out — locks #6)"
grep -qE '^\s*command -v codex .*\|\| npm i -g' scripts/cloud-setup.sh && ok "cloud-setup.sh actually ATTEMPTS the CLI installs (uncommented)" || no "cloud-setup.sh installs are still commented out"
grep -qiE 'best-effort|adjust the package names' README.md && ok "README is honest about best-effort installs" || no "README overclaims that setup installs"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
