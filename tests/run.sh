#!/usr/bin/env bash
# Self-test harness for the Parallax plugin. Run from anywhere: `bash tests/run.sh`.
# Where it can, it EXECUTES the real mechanic (git integration, the lock, bash -n on every
# code block, schema validation) rather than grepping for a string — grep gave false
# confidence in earlier versions. LLM-orchestration semantics (mode judgments, timeouts)
# are NOT unit-tested here; those are for integration runs / the Ralphex benchmark.
# Deps: python3 (+ optional jsonschema), git.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1     # don't let the harness's python invocations create __pycache__ (see [no_pyc])
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
r=d['review']; assert r['pre_freeze_max_rounds']==2 and r['max_rounds']==2 and r['resume_codex_session'] is False and r['recheck_fixed'] is True
assert r['block_severities']==["medium","high"] and r['advisory_severities']==["low"]
assert set(r['always_block_kinds'])=={"safety","anti-cheat","spec-gap"}, r['always_block_kinds']
PY

echo "[pre_freeze_budget]  (EXECUTES: base cap, exact one-round human grant, raw receipts, frozen policy)"
if ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
  echo "  · jsonschema not installed — pre-freeze budget happy-path test skipped (the gate itself fails closed)"
else
  PFT=$(mktemp -d); PFS="$PFT/pre-freeze-state.json"; PFP="$PFT/codex.toml"
  cp assets/codex/codex.toml.example "$PFP"
  printf 'candidate spec\n' > "$PFT/spec.md"
  printf 'candidate slices\n' > "$PFT/slices.md"
  printf 'candidate validation\n' > "$PFT/validation.md"
  printf '{"slug":"demo","slices":["S1"]}\n' > "$PFT/slices.lock"
  PF_CONTRACT=(--contract-file "$PFT/spec.md" --contract-file "$PFT/slices.md" \
               --contract-file "$PFT/validation.md" --contract-file "$PFT/slices.lock")
  for n in 1 2 3; do
    printf '%s\n' '{"verdict":"concerns","findings":[{"severity":"high","kind":"spec-gap","where":"B1","detail":"observable divergence"}]}' > "$PFT/r$n.json"
  done
  pf(){ python3 scripts/pre-freeze-budget.py "$@"; }
  PF_BAD=0
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf1 || PF_BAD=1
  pf record "$PFS" "$PFT/r1.json" --policy "$PFP" --slug demo --provider codex "${PF_CONTRACT[@]}" >/tmp/parallax_pf2 || PF_BAD=1
  pf record "$PFS" "$PFT/r2.json" --policy "$PFP" --slug demo --provider codex "${PF_CONTRACT[@]}" >/tmp/parallax_pf3; PF_R2=$?
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf4; PF_CAP=$?
  pf grant-one "$PFS" --policy "$PFP" --slug demo --token 'owner-chose-product-option-A' >/tmp/parallax_pf5; PF_FAKE=$?
  TOKEN=$(python3 -c 'import json; print(json.load(open("/tmp/parallax_pf4"))["grant_token"])')
  pf grant-one "$PFS" --policy "$PFP" --slug demo --token "$TOKEN" >/tmp/parallax_pf6 || PF_BAD=1
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf7 || PF_BAD=1
  pf record "$PFS" "$PFT/r3.json" --policy "$PFP" --slug demo --provider codex "${PF_CONTRACT[@]}" >/tmp/parallax_pf8; PF_R3=$?
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf9; PF_RECAP=$?
  printf 'tampered spec\n' > "$PFT/pre_freeze.round1.contract/spec.md"
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf_tamper; PF_TAMPER=$?
  printf 'candidate spec\n' > "$PFT/pre_freeze.round1.contract/spec.md"
  printf '\n# policy drift\n' >> "$PFP"
  pf check "$PFS" --policy "$PFP" --slug demo >/tmp/parallax_pf10; PF_DRIFT=$?
  python3 - "$PFS" <<'PY' >/tmp/parallax_pf_state || PF_BAD=1
import json, os, sys
s=json.load(open(sys.argv[1]))
assert s["rounds_used"] == 3 and len(s["grants"]) == 1 and s["grants"][0]["round"] == 3
assert [r["round"] for r in s["rounds"]] == [1,2,3]
assert all(os.path.exists(os.path.join(os.path.dirname(sys.argv[1]),r["artifact"])) for r in s["rounds"])
assert all(os.path.isdir(os.path.join(os.path.dirname(sys.argv[1]),r["contract_dir"])) for r in s["rounds"])
assert all(len(r["contract_hash"]) == 64 for r in s["rounds"])
assert s["closure"] == {"status": "open"}, s["closure"]   # v0.37.3 F3: three concerns rounds never close
PY
  if [ "$PF_BAD" = 0 ] && [ "$PF_R2" = 2 ] && [ "$PF_CAP" = 2 ] && [ "$PF_FAKE" = 2 ] \
     && [ "$PF_R3" = 2 ] && [ "$PF_RECAP" = 2 ] && [ "$PF_TAMPER" = 2 ] && [ "$PF_DRIFT" = 2 ]; then
    ok "pre-freeze: 2-round cap; unrelated answer cannot grant; token grants one round; round 4, receipt tamper, policy drift block"
  else
    no "pre-freeze budget gate failed (bad=$PF_BAD r2=$PF_R2 cap=$PF_CAP fake=$PF_FAKE r3=$PF_R3 recap=$PF_RECAP tamper=$PF_TAMPER drift=$PF_DRIFT)"
  fi
  rm -rf "$PFT"
fi

echo "[pre_freeze_closure]  (v0.37.3 F3 — EXECUTES pre-freeze-budget.py closure: only a schema-valid verifier PASS closes; self-attestation cannot)"
bash tests/t_pre_freeze_closure.sh >/tmp/parallax_pfcl 2>&1; pfclrc=$?
if [ "$pfclrc" = 2 ] && grep -q SKIP /tmp/parallax_pfcl; then echo "  · jsonschema not installed — closure execution test skipped (the gate itself fails closed)";
elif [ "$pfclrc" = 0 ]; then ok "closure: verifier pass -> independent-pass (machine-derived, surfaced by check); concerns at cap stays checkpoint+open; bolted-on all_resolved, hand-flipped independent-pass, closed_by=orchestrator, and a doctored open over a real pass ALL rejected; a human grant authorizes one round and closes nothing itself"; else no "pre-freeze closure (F3)"; sed 's/^/      /' /tmp/parallax_pfcl; fi
python3 - <<'PY' && ok "pre-freeze-state schema: closure required; status enum exactly {open, independent-pass} (no self-attested value representable); closed_by is a machine const" || no "pre-freeze-state closure schema shape wrong (F3)"
import json
s = json.load(open('assets/codex/pre-freeze-state.schema.json'))
assert "closure" in s["required"], s["required"]
c = s["properties"]["closure"]
assert set(c["properties"]["status"]["enum"]) == {"open", "independent-pass"}
assert c["properties"]["closed_by"] == {"const": "independent-verifier"}
assert c["additionalProperties"] is False
PY
{ grep -qF -- 'Autonomous mode is the flag COMBINATION `--autonomous --from-doc' commands/spec.md \
  && grep -qF -- 'never `--from-doc` alone' commands/spec.md \
  && ! grep -qF -- '**Autonomous mode** (`--from-doc`)' commands/spec.md \
  && ! grep -qF -- '*Autonomous (`--from-doc`):*' commands/spec.md; } \
  && ok "spec.md flag semantics: every no-human-OK path requires --autonomous --from-doc together; the two bare --from-doc autonomous gates (old lines 34/153) are gone; plain --from-doc stays human-gated intake" \
  || no "spec.md still gates a no-human-OK path on bare --from-doc (F3)"
{ grep -qF 'Pre-freeze closure, mechanically' commands/spec.md && grep -qF 'independent-pass' commands/spec.md \
  && grep -qF 'grant-one' commands/spec.md; } \
  && ok "spec.md wires the closure mechanics: autonomous freeze requires closure.status=independent-pass; a grant authorizes one round, never certifies" \
  || no "spec.md closure wiring missing (F3)"

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
for a in ['assets/codex/verdict.schema.json','assets/codex/spec-adversary.schema.json','assets/codex/pre-freeze-state.schema.json','assets/run-state.schema.json','scripts/pre-freeze-budget.py']: assert os.path.exists(a),a
PY

echo "[shell_syntax]  (EXECUTES bash -n on every fenced bash block in run.md + resolve.md — locks P5)"
python3 - <<'PY'
import re
t=''.join(open(p).read() for p in ('commands/run.md','commands/resolve.md')); n=0
for m in re.findall(r'```bash\n(.*?)```', t, re.S):
    s=re.sub(r'<[^>\n]*>','PH',m)           # neutralize <placeholders>
    open(f'/tmp/parallax_blk{n}.sh','w').write(s); n+=1
open('/tmp/parallax_nblk','w').write(str(n))
PY
nblk=$(cat /tmp/parallax_nblk); bad=0
for i in $(seq 0 $((nblk-1))); do bash -n "/tmp/parallax_blk$i.sh" 2>/tmp/parallax_syn || { bad=1; echo "      block $i: $(cat /tmp/parallax_syn)"; }; done
[ "$bad" = 0 ] && ok "all $nblk run.md + resolve.md bash blocks pass bash -n" || no "a run.md/resolve.md bash block has a shell syntax error"

echo "[integration]  (EXECUTES the parallel wave — locks v0.19 #1 data-loss + #2 assembly worktree + #3 transactional + #4 binary)"
bash tests/t_assembly.sh feature/ >/tmp/parallax_int1 2>&1 && ok "per-slice diff integration preserves a 2-slice wave (prefix feature/)" || { no "integration (feature/)"; sed 's/^/      /' /tmp/parallax_int1; }
bash tests/t_assembly.sh claude/  >/tmp/parallax_int2 2>&1 && ok "same works under a non-default prefix (claude/ — cloud routine)" || { no "integration (claude/)"; sed 's/^/      /' /tmp/parallax_int2; }
bash tests/t_binary.sh   >/tmp/parallax_bin  2>&1 && ok "binary files integrate via 'git diff --binary | git apply --binary' (a plain diff fails)" || { no "binary integration (#4)"; sed 's/^/      /' /tmp/parallax_bin; }
bash tests/t_conflict.sh >/tmp/parallax_cflt 2>&1 && ok "transactional: a wave conflict rolls back in the assembly worktree; feature/<slug> never moves" || { no "transactional integration (#2/#3)"; sed 's/^/      /' /tmp/parallax_cflt; }
{ grep -q "Applying only the delta" commands/run.md && grep -q "Do \*\*not\*\* mirror" commands/run.md; } && ok "run.md documents delta integration AND warns against mirror" || no "run.md no longer documents delta-not-mirror integration"
grep -q "assembly worktree" commands/run.md && ok "run.md documents the per-slice assembly worktree + transactional integrate" || no "run.md missing assembly-worktree integration"

echo "[lock]  (EXECUTES the documented lock — locks v0.19 #1 cloud same-HEAD race)"
bash tests/t_lock.sh >/tmp/parallax_lock 2>&1 && ok "lock: unique commit + force-with-lease yields one winner across same-HEAD clones (old same-value let both win)" || { no "lock"; sed 's/^/      /' /tmp/parallax_lock; }

echo "[runstate_schema]  (EXECUTES validation — locks v0.19 #5 exact-resume completeness: wave_base, running→lock, paused→paused, hex SHAs)"
python3 - <<'PY' >/tmp/parallax_rs 2>&1
import json, copy
try: import jsonschema
except ImportError: print("SKIP"); raise SystemExit
s=json.load(open('assets/run-state.schema.json'))
H="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"   # valid 40-hex object id
ok_full={"run_id":"r","slug":"d","epic":"e","base_tip":H,"status":"running",
  "slices":[{"id":"S1","status":"green-unverified","arbiter_verdict":"green","verified_diff":H,"wave_base":H},
            {"id":"S2","status":"in_progress","code_tip":H,"test_tip":H,"wave_base":H}],
  "lock":{"holder":"r","acquired_at":"t","expires_at":"t2"},"updated_at":"t"}
jsonschema.validate(ok_full,s)
def rejects(doc):
    try: jsonschema.validate(doc,s); return False
    except Exception: return True
a=copy.deepcopy(ok_full); a["slices"]=[{"id":"S1","status":"green-unverified"}]                 # missing verdict/diff/wave_base
b=copy.deepcopy(ok_full); b["slices"]=[{"id":"S2","status":"in_progress","code_tip":H,"test_tip":H}]  # missing wave_base
c=copy.deepcopy(ok_full); c.pop("lock")                                                          # running but no lock
d=copy.deepcopy(ok_full); d["status"]="paused-on-limit"; d.pop("lock")                           # paused but no paused block
e=copy.deepcopy(ok_full); e["base_tip"]="not-a-sha"                                              # non-hex tip
print("OK" if all(rejects(x) for x in (a,b,c,d,e)) else "ACCEPTED_BAD")
PY
R=$(cat /tmp/parallax_rs)
if [ "$R" = "SKIP" ]; then echo "  · jsonschema not installed — schema-completeness test skipped";
elif [ "$R" = "OK" ]; then ok "schema accepts a complete checkpoint and REJECTS 5 incomplete/invalid ones (wave_base, running→lock, paused→paused, hex SHA)"; else no "schema accepts an incomplete/invalid checkpoint ($R)"; fi

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

echo "[verifier_contracts]  (v0.19 #6/#8 — sole RED-arbitration kinds + real wall-clock timeouts)"
python3 - <<'PY' && ok "verdict schema includes code-fault/test-fault kinds (sole RED arbitration)" || no "verdict schema missing code-fault/test-fault"
import json
e=json.load(open('assets/codex/verdict.schema.json'))["properties"]["findings"]["items"]["properties"]["kind"]["enum"]
assert "code-fault" in e and "test-fault" in e, e
PY
{ grep -qF 'timeout "$TIMEOUT_S" codex exec' skills/role-codex-judge/SKILL.md && grep -qF 'timeout "$TIMEOUT_S" gemini' skills/role-codex-judge/SKILL.md && grep -qF 'curl --max-time "$TIMEOUT_S"' skills/role-codex-judge/SKILL.md; } \
  && ok "role-codex-judge wraps codex/gemini/curl in a real timeout_s wall-clock guard" || no "role-codex-judge missing a real timeout wrapper"
grep -q "Sole mode — RED arbitration" skills/role-codex-judge/SKILL.md && ok "role-codex-judge documents sole-mode RED arbitration (3rd behavior)" || no "role-codex-judge missing sole RED arbitration"

echo "[review_triage]  (v0.21 — EXECUTES triage.py: policy from TRUSTED toml only; fixed needs codex proof)"
python3 - <<'PY' >/tmp/parallax_triage 2>&1
import json,subprocess
TOML="assets/codex/codex.toml.example"; D="a"*40; E="b"*40
def dec(led,diff=D):
    # --no-schema-check isolates triage LOGIC (fail-closed schema validation is tested in [review_failclosed])
    p=subprocess.run(["python3","scripts/triage.py","-","--policy",TOML,"--current-diff",diff,"--no-schema-check"],
                     input=json.dumps(led),capture_output=True,text=True)
    try: return json.loads(p.stdout)["decision"], p.returncode
    except Exception: return ("PARSE_ERR:"+p.stdout+p.stderr), p.returncode
def F(**k):
    k.setdefault("status","open"); k.setdefault("spec_ref","spec#x"); k.setdefault("where","src/x.ts:1")
    k.setdefault("claim","c"); k.setdefault("evidence","e"); k.setdefault("fingerprint","f"); return k
PERMISSIVE={"always_block_kinds":[],"block_severities":[],"advisory_severities":["low","medium","high"]}
cases=[
 ("low->advisory/green",         {"rounds_used":0,"findings":[F(id="a",severity="low",kind="missing-edge")]},               D,"green",0),
 ("high safety->block",          {"rounds_used":0,"findings":[F(id="a",severity="high",kind="safety")]},                    D,"block",1),
 ("P0#1 ledger policy IGNORED",  {"rounds_used":0,"policy":PERMISSIVE,"findings":[F(id="a",severity="high",kind="safety")]},D,"block",1),
 ("P0#2 faked fixed (no codex)", {"rounds_used":1,"findings":[F(id="a",severity="high",kind="safety",status="fixed")]},     D,"block",1),
 ("codex-verified fixed@D",      {"rounds_used":1,"findings":[F(id="a",severity="high",kind="safety",status="fixed",verified_by="codex",last_verified_diff=D)]},D,"green",0),
 ("stale verify (tree moved)",   {"rounds_used":1,"findings":[F(id="a",severity="high",kind="safety",status="fixed",verified_by="codex",last_verified_diff=D)]},E,"block",1),
 ("medium->block",               {"rounds_used":0,"findings":[F(id="a",severity="medium",kind="missing-edge")]},            D,"block",1),
 ("contest medium->escalate",    {"rounds_used":0,"findings":[F(id="a",severity="medium",kind="missing-edge",claude_rebuttal={"reason":"out-of-scope"})]},D,"escalate",2),
 ("bogus rebuttal->block",       {"rounds_used":0,"findings":[F(id="a",severity="medium",kind="missing-edge",claude_rebuttal={"reason":"nope"})]},D,"block",1),
 ("budget exhausted->escalate",  {"rounds_used":2,"findings":[F(id="a",severity="medium",kind="missing-edge")]},            D,"escalate",2),
]
bad=[[n,d,rc,xd,xrc] for n,led,diff,xd,xrc in cases for d,rc in [dec(led,diff)] if d!=xd or rc!=xrc]
print("OK" if not bad else "BAD "+json.dumps(bad))
PY
R=$(cat /tmp/parallax_triage)
[ "$R" = OK ] && ok "triage: ledger-policy IGNORED, faked-fixed BLOCKS, only codex-verified-vs-current-diff settles, stale verify re-blocks" || { no "triage hardening wrong"; echo "      $R"; }

echo "[merge_ledger]  (EXECUTES merge-ledger.py: the producer never authors findings)"
python3 - <<'PY' >/tmp/parallax_ml 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); D1="a"*40; D2="b"*40; D3="c"*40
def rnd(d): p=os.path.join(T,"r.json"); json.dump(d,open(p,"w")); return p
def merge(rp,diff): subprocess.run(["python3","scripts/merge-ledger.py",L,rp,"--slice","S1","--current-diff",diff,"--slug","demo"],capture_output=True,text=True,check=True)
# round 1: a high safety finding
merge(rnd({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"spec#a","where":"src/x.ts:42","claim":"c","evidence":"e"}],"resolved":[]}),D1)
l=json.load(open(L)); f=l["findings"][0]
assert len(l["findings"])==1 and f["status"]=="open" and f.get("fingerprint") and l["rounds_used"]==1, ("r1",l)
# round 2: verifier positively RESOLVES it -> fixed + verified_by=codex (Claude cannot do this)
merge(rnd({"verdict":"pass","findings":[],"resolved":[{"kind":"safety","spec_ref":"spec#a","where":"src/x.ts:99","note":"fixed"}]}),D2)
l=json.load(open(L)); f=l["findings"][0]
assert f["status"]=="fixed" and f["verified_by"]=="codex" and f["last_verified_diff"]==D2 and l["rounds_used"]==2, ("r2",l)
# round 3: SAME defect re-reported, rephrased + new line -> SAME id (fingerprint), status regressed, no new finding
merge(rnd({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"spec#a","where":"src/x.ts:120","claim":"again","evidence":"retry"}],"resolved":[]}),D3)
l=json.load(open(L))
assert len(l["findings"])==1 and l["findings"][0]["status"]=="regressed" and l["rounds_used"]==3, ("r3",l)
print("OK")
PY
R=$(cat /tmp/parallax_ml)
[ "$R" = OK ] && ok "merge-ledger: verifier-authored findings, resolved->fixed+verified_by=codex, fingerprint reuses the id, rounds_used++" || { no "merge-ledger wrong"; echo "      $R"; }

echo "[review_schemas]  (EXECUTES validation — ledger fixed needs codex proof; round verdict↔findings consistent)"
python3 - <<'PY' >/tmp/parallax_rs2 2>&1
import json, copy
try: import jsonschema
except ImportError: print("SKIP"); raise SystemExit
LS=json.load(open('assets/codex/review-ledger.schema.json')); RS=json.load(open('assets/codex/review-round.schema.json')); VS=json.load(open('assets/codex/verdict.schema.json'))
def rej(doc,s):
    try: jsonschema.validate(doc,s); return False
    except Exception: return True
gl={"slug":"d","slice_id":"S1","rounds_used":1,"findings":[{"id":"S1-N1","fingerprint":"f","severity":"low","kind":"missing-edge","spec_ref":"spec#x","claim":"c","evidence":"e","status":"open"}]}
jsonschema.validate(gl,LS)
l_nospec=copy.deepcopy(gl); del l_nospec["findings"][0]["spec_ref"]
l_noslice=copy.deepcopy(gl); del l_noslice["slice_id"]
l_fixed_noproof=copy.deepcopy(gl); l_fixed_noproof["findings"][0]["status"]="fixed"          # P0#2 at schema layer
l_policy=copy.deepcopy(gl); l_policy["policy"]={"always_block_kinds":[]}                       # P0#1 at schema layer
gr={"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"s#x","where":"src/x:1","claim":"c","evidence":"e"}]}
jsonschema.validate(gr,RS); jsonschema.validate({"verdict":"pass","findings":[]},RS)
r_passnonempty={"verdict":"pass","findings":[{"severity":"low","kind":"missing-edge","spec_ref":"s","where":"w","claim":"c","evidence":"e"}]}
r_concernsempty={"verdict":"concerns","findings":[]}
r_nospec={"verdict":"concerns","findings":[{"severity":"low","kind":"missing-edge","where":"w","claim":"c","evidence":"e"}]}
v_passnonempty={"verdict":"pass","findings":[{"severity":"low","kind":"missing-edge","where":"w","detail":"d"}]}
checks=[rej(l_nospec,LS),rej(l_noslice,LS),rej(l_fixed_noproof,LS),rej(l_policy,LS),
        rej(r_passnonempty,RS),rej(r_concernsempty,RS),rej(r_nospec,RS),rej(v_passnonempty,VS)]
print("OK" if all(checks) else "ACCEPTED_BAD "+json.dumps(checks))
PY
R=$(cat /tmp/parallax_rs2)
if [ "$R" = SKIP ]; then echo "  · jsonschema not installed — schema-hardening test skipped";
elif [ "$R" = OK ]; then ok "schemas reject: fixed-without-codex-proof, a policy-bearing ledger, missing slice_id/spec_ref, and pass+findings / concerns+empty"; else no "schema hardening too lax ($R)"; fi

echo "[review_contracts]  (presence — producer-proof wiring is documented)"
{ grep -qi "no anchoring" skills/role-codex-judge/SKILL.md && grep -q "review-round" skills/role-codex-judge/SKILL.md && grep -q "merge-ledger.py" skills/role-codex-judge/SKILL.md && grep -q "reviews/<slice_id>.json" skills/role-codex-judge/SKILL.md; } && ok "role-codex-judge: fresh per-slice review, emits a review-round, mechanical merge" || no "role-codex-judge missing v0.21 producer-proof protocol"
{ grep -q "scripts/merge-ledger.py" commands/run.md && grep -qF "scripts/triage.py \"\$LEDGER\" --policy \"\$POLICY\"" commands/run.md && grep -q "reviews/\$SID.json" commands/run.md && grep -qF 'LEDGER="$ASSEMBLED/$REL_LEDGER"' commands/run.md; } && ok "run.md wires merge-ledger + triage(--policy from committed toml) + per-slice ledger bound to the assembly worktree" || no "run.md missing producer-proof pipeline"
grep -q "never checked out in parallel" commands/run.md && ok "run.md: feature branch not checked out in parallel (no stale worktree on CAS)" || no "run.md missing no-checkout-in-parallel"

echo "[reviewed_commit]  (v0.23 P0#1 + P1#5 — EXECUTES: commit == reviewed tree + receipt; scoped guard ignores the ledger)"
bash tests/t_difftree.sh >/tmp/parallax_dt 2>&1 && ok "reviewed-content hash tracks code (not HEAD^{tree}); scoped guard ignores a tracked ledger (P1#5); receipt-only add keeps untracked files out (P0#1)" || { no "reviewed commit / scoped guard (P0#1/P1#5)"; sed 's/^/      /' /tmp/parallax_dt; }
{ grep -qF 'git -C "$ASSEMBLED" ls-files -s' commands/run.md \
  && grep -qF 'git hash-object --stdin' commands/run.md \
  && grep -qF 'git -C "$ASSEMBLED" diff --quiet -- "${SRC_PATHSPECS[@]}"' commands/run.md \
  && grep -qF 'git -C "$ASSEMBLED" add -- "$REL_LEDGER"' commands/run.md \
  && ! grep -qF 'git add -A && git commit' commands/run.md \
  && ! grep -qF 'git -C "$ASSEMBLED" rev-parse "HEAD^{tree}"' commands/run.md; } \
  && ok "run.md 2c: DIFF=reviewed-tree hash, scoped guard, receipt-only add (no 'git add -A && git commit'), no HEAD^{tree}" || no "run.md 2c commit/guard not hardened per v0.23"

echo "[parallel_ledger]  (v0.23 P0#2 — EXECUTES: the review ledger rides into the integrated commit)"
bash tests/t_parallel_ledger.sh >/tmp/parallax_pl 2>&1 && ok "parallel integration carries .parallax/<slug>/reviews/ into the CAS commit (ledger not dropped); integrated == reviewed" || { no "parallel integration drops the ledger (P0#2)"; sed 's/^/      /' /tmp/parallax_pl; }
grep -qF '".parallax/$SLUG/reviews/"' commands/run.md && ok "run.md integration delta includes the review-receipt path (sourced from the green commit)" || no "run.md integration omits .parallax/<slug>/reviews/"

echo "[id_consistency]  (v0.23 P1#3 — EXECUTES: a cited id with mismatched metadata cannot close a finding)"
python3 - <<'PY' >/tmp/parallax_idc 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); D="a"*40
def merge(d): p=os.path.join(T,"r.json"); json.dump(d,open(p,"w")); subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff",D,"--slug","demo"],capture_output=True,text=True,check=True)
merge({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"spec#auth","where":"src/auth.ts:7","claim":"hole","evidence":"e"}],"resolved":[]})
# resolve citing N1's id but UNRELATED metadata -> must be ignored; the safety finding stays open
merge({"verdict":"concerns","findings":[],"resolved":[{"id":"S1-N1","kind":"missing-edge","spec_ref":"spec#OTHER","where":"src/other.ts:99","note":"bad"}]})
bad = (json.load(open(L))["findings"][0]["status"] != "open")
# correct id + matching metadata DOES close it
merge({"verdict":"concerns","findings":[],"resolved":[{"id":"S1-N1","kind":"safety","spec_ref":"spec#auth","where":"src/auth.ts:7","note":"real"}]})
g=json.load(open(L))["findings"][0]; good = (g["status"]=="fixed" and g.get("verified_by")=="codex")
print("OK" if (not bad and good) else f"BAD bad-id-closed={bad} good-id-failed={not good}")
PY
R=$(cat /tmp/parallax_idc)
[ "$R" = OK ] && ok "exact-id honored ONLY when kind/spec_ref/file match (bad-id ignored, correct-id settles)" || { no "id-consistency wrong"; echo "      $R"; }

echo "[ledger_restamp]  (v0.23 — EXECUTES: a re-confirmed fix re-stamps to the current diff so multi-round slices converge, not falsely block)"
python3 - <<'PY' >/tmp/parallax_rst 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); D1="a"*40; D2="b"*40
def merge(d,diff): p=os.path.join(T,"r.json"); json.dump(d,open(p,"w")); subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff",diff,"--slug","demo"],capture_output=True,text=True,check=True)
merge({"verdict":"concerns","findings":[{"severity":"high","kind":"code-fault","spec_ref":"s#A","where":"src/a.ts:1","claim":"A","evidence":"e"}],"resolved":[]},D1)  # r1@D1: A open
# r2@D2 (code changed for a sibling): A re-confirmed fixed (cite id) + NEW finding B
merge({"verdict":"concerns","findings":[{"severity":"high","kind":"code-fault","spec_ref":"s#B","where":"src/b.ts:1","claim":"B","evidence":"e"}],
       "resolved":[{"id":"S1-N1","kind":"code-fault","spec_ref":"s#A","where":"src/a.ts:1","note":"holds"}]},D2)
A=[f for f in json.load(open(L))["findings"] if f["id"]=="S1-N1"][0]
ok_A = (A["status"]=="fixed" and A["last_verified_diff"]==D2)               # re-stamped to the CURRENT tree, not stale D1
merge({"verdict":"pass","findings":[],"resolved":[{"id":"S1-N2","kind":"code-fault","spec_ref":"s#B","where":"src/b.ts:1","note":"fixed"}]},D2)  # r3@D2: B fixed
dec=json.loads(subprocess.run(["python3","scripts/triage.py",L,"--policy","assets/codex/codex.toml.example","--current-diff",D2,"--no-schema-check"],capture_output=True,text=True).stdout)["decision"]
print("OK" if (ok_A and dec=="green") else f"BAD ok_A={ok_A} decision={dec}")
PY
R=$(cat /tmp/parallax_rst)
[ "$R" = OK ] && ok "a re-confirmed fix re-stamps last_verified_diff to the current tree (multi-round slice converges to green)" || { no "re-stamp/convergence wrong"; echo "      $R"; }

echo "[policy_freeze]  (v0.26 P0#2 — EXECUTES: the [review] policy is frozen per run; a mid-run swap PARKS, never re-stamps policy_hash)"
python3 - <<'PY' >/tmp/parallax_pf 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); STRICT="assets/codex/codex.toml.example"
PERM=os.path.join(T,"perm.toml"); open(PERM,"w").write('[review]\nmax_rounds=2\nblock_severities=[]\nadvisory_severities=["low","medium","high"]\nalways_block_kinds=[]\n')
def merge(rj,policy):
    p=os.path.join(T,"r.json"); json.dump(rj,open(p,"w"))
    return subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff","a"*40,"--slug","demo","--policy",policy],capture_output=True,text=True).returncode
r1=merge({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"s","where":"src/a:1","claim":"c","evidence":"e"}],"resolved":[]}, STRICT)
h1=json.load(open(L)).get("policy_hash")
r2=merge({"verdict":"pass","findings":[],"resolved":[]}, PERM)        # mid-run swap to permissive -> must PARK
h2=json.load(open(L)).get("policy_hash")
r3=merge({"verdict":"pass","findings":[],"resolved":[]}, STRICT)      # same frozen policy -> proceeds
print("OK" if (r1==0 and r2!=0 and h1==h2 and r3==0) else f"BAD r1={r1} r2={r2} r3={r3} unchanged={h1==h2}")
PY
R=$(cat /tmp/parallax_pf)
[ "$R" = OK ] && ok "merge-ledger freezes policy_hash: a mid-run policy change PARKS (exit!=0) and never re-stamps; the frozen policy proceeds" || { no "policy not frozen per run"; echo "      $R"; }
grep -qF 'PARK: review policy or spec contract changed mid-run' commands/run.md && ok "run.md parks the run on a mid-run policy/contract change (merge-ledger non-zero)" || no "run.md does not park on policy/contract drift"

echo "[contract_freeze]  (v0.27 P0 — EXECUTES: the frozen spec contract is bound; mid-run change PARKS, gate recomputes contract_hash)"
python3 - <<'PY' >/tmp/parallax_cf 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); STRICT="assets/codex/codex.toml.example"
def merge(rj,contract_hash):
    p=os.path.join(T,"r.json"); json.dump(rj,open(p,"w"))
    return subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff","a"*40,"--slug","demo","--policy",STRICT,"--contract-hash",contract_hash],capture_output=True,text=True).returncode
r1=merge({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"s","where":"src/a:1","claim":"c","evidence":"e"}],"resolved":[]}, "contractAAAA")
c1=json.load(open(L)).get("contract_hash")
r2=merge({"verdict":"pass","findings":[],"resolved":[]}, "contractBBBB")    # spec rewritten mid-run -> must PARK
c2=json.load(open(L)).get("contract_hash")
r3=merge({"verdict":"pass","findings":[],"resolved":[]}, "contractAAAA")    # same frozen contract -> proceeds
print("OK" if (r1==0 and r2!=0 and c1=="contractAAAA" and c2=="contractAAAA" and r3==0) else f"BAD r1={r1} r2={r2} r3={r3} c1={c1} c2={c2}")
PY
R=$(cat /tmp/parallax_cf)
[ "$R" = OK ] && ok "merge-ledger freezes contract_hash too: a mid-run spec/validation change PARKS and never re-stamps; the frozen contract proceeds" || { no "contract not frozen per run"; echo "      $R"; }
{ grep -qF 'scripts/contract-hash.sh' commands/run.md && grep -qF -- '--contract-hash "$CONTRACT_HASH"' commands/run.md; } && ok "run.md computes + stamps the frozen contract_hash (merge-ledger --contract-hash)" || no "run.md does not stamp contract_hash"

echo "[contract_guard]  (v0.28 P0 — EXECUTES: the worktree contract must equal HEAD, so the stamped hash == what the verifier read)"
bash tests/t_contract_guard.sh >/tmp/parallax_cg 2>&1 && ok "contract guard: an uncommitted spec edit (verifier reads the worktree) is caught by 'git diff --quiet HEAD -- <contract>'; an untracked contract file by ls-files --others — the src/tests guard misses both" || { no "worktree contract guard (P0)"; sed 's/^/      /' /tmp/parallax_cg; }
{ grep -qF 'git -C "$ASSEMBLED" diff --quiet HEAD -- "${CONTRACT_PATHS[@]}"' commands/run.md \
  && grep -qF 'ls-files --others --exclude-standard -- "${CONTRACT_PATHS[@]}"' commands/run.md; } \
  && ok "run.md guards the worktree contract == HEAD (diff HEAD + untracked) before stamping contract_hash" || no "run.md missing the worktree-contract guard"

echo "[pass_through_ledger]  (v0.22 P0#2 — EXECUTES: a Codex 'pass' that omits a prior open finding still blocks)"
python3 - <<'PY' >/tmp/parallax_ptl 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); D="a"*40
def merge(d): p=os.path.join(T,"r.json"); json.dump(d,open(p,"w")); subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff",D,"--slug","demo"],capture_output=True,text=True,check=True)
merge({"verdict":"concerns","findings":[{"severity":"high","kind":"safety","spec_ref":"s#a","where":"src/a.ts:1","claim":"c","evidence":"e"}],"resolved":[]})  # round 1: open high-safety
merge({"verdict":"pass","findings":[],"resolved":[]})                                                                                                        # round 2: bare PASS, omits it
p=subprocess.run(["python3","scripts/triage.py",L,"--policy","assets/codex/codex.toml.example","--current-diff",D,"--no-schema-check"],capture_output=True,text=True)
dec=json.loads(p.stdout)["decision"]
print("OK" if (dec!="green" and p.returncode!=0) else "BAD pass-bypassed-ledger decision="+dec)
PY
R=$(cat /tmp/parallax_ptl)
[ "$R" = OK ] && ok "a 'pass' routed through merge+triage does NOT green a slice with a prior open finding" || { no "pass bypasses the ledger"; echo "      $R"; }
grep -qF 'does NOT bypass the ledger' commands/run.md && ok "run.md routes BOTH pass and concerns through merge-ledger + triage (no commit-on-pass shortcut)" || no "run.md still commits directly on Codex pass"

echo "[review_failclosed]  (v0.22 P0#3 — EXECUTES: no jsonschema => escalate, never green)"
FAKE=$(mktemp -d); echo 'raise ImportError("simulated: jsonschema missing")' > "$FAKE/jsonschema.py"
HID=$(echo '{}' | PYTHONPATH="$FAKE" python3 scripts/triage.py - --policy assets/codex/codex.toml.example --current-diff aaaa 2>/dev/null); HRC=$?
OPT=$(echo '{}' | python3 scripts/triage.py - --policy assets/codex/codex.toml.example --current-diff aaaa --no-schema-check 2>/dev/null); ORC=$?
rm -rf "$FAKE"
{ echo "$HID" | grep -q '"decision": "escalate"' && [ "$HRC" = 2 ] && echo "$OPT" | grep -q '"decision": "green"' && [ "$ORC" = 0 ]; } \
  && ok "triage fails CLOSED with no validator (escalate/2); --no-schema-check is the only opt-out (green/0)" \
  || { no "triage still fails OPEN without jsonschema"; echo "      hidden=[$HID] rc=$HRC ; optout=[$OPT] rc=$ORC"; }

echo "[merge_ledger_collision]  (v0.22 P1#4 — EXECUTES: same-fingerprint distinct defects don't collapse; resolve by exact id)"
python3 - <<'PY' >/tmp/parallax_mlc 2>&1
import json,subprocess,tempfile,os
T=tempfile.mkdtemp(); L=os.path.join(T,"S1.json"); D1="a"*40; D2="b"*40
def merge(d,diff): p=os.path.join(T,"r.json"); json.dump(d,open(p,"w")); subprocess.run(["python3","scripts/merge-ledger.py",L,p,"--slice","S1","--current-diff",diff,"--slug","demo"],capture_output=True,text=True,check=True)
# two DIFFERENT defects, identical kind|spec_ref|file -> same fingerprint, must NOT collapse to one
merge({"verdict":"concerns","findings":[
  {"severity":"high","kind":"code-fault","spec_ref":"spec#B10","where":"src/o.ts:10","claim":"ONE","evidence":"e1"},
  {"severity":"high","kind":"code-fault","spec_ref":"spec#B10","where":"src/o.ts:55","claim":"TWO","evidence":"e2"}],"resolved":[]},D1)
l=json.load(open(L)); assert len(l["findings"])==2, ("collapsed",l)
# resolve N1 by EXACT id while re-reporting N2 (cites id) -> N1 fixed, N2 still open (no false settle, no loss)
merge({"verdict":"concerns","findings":[{"id":"S1-N2","severity":"high","kind":"code-fault","spec_ref":"spec#B10","where":"src/o.ts:60","claim":"TWO again","evidence":"e2"}],
       "resolved":[{"id":"S1-N1","kind":"code-fault","spec_ref":"spec#B10","where":"src/o.ts:10","note":"fixed one"}]},D2)
l=json.load(open(L)); st={f["id"]:f["status"] for f in l["findings"]}
assert st=={"S1-N1":"fixed","S1-N2":"open"}, st
print("OK")
PY
R=$(cat /tmp/parallax_mlc)
[ "$R" = OK ] && ok "two same-fingerprint defects stay distinct; resolve-by-id settles exactly one (no data loss)" || { no "merge-ledger collision handling wrong"; echo "      $R"; }

echo "[epic_gate]  (v0.27 — EXECUTES epic-gate.py against REAL git repos: a feature-level receipt bound to the promoted commit)"
bash tests/t_epic_gate.sh >/tmp/parallax_eg 2>&1; egrc=$?
if [ "$egrc" = 2 ]; then echo "  · jsonschema not installed — epic-gate execution test skipped";
elif [ "$egrc" = 0 ]; then ok "epic-gate.py holds on: code-changed, spec/validation-rewritten-after-review (contract_hash), missing/identity-/slug-mismatched ledger, parked slice, rounds_used<1, status!=complete, dropped slice vs slices.lock, committed-policy swap, internal-slug tamper; verifies only a clean committed complete run"; else no "epic-gate.py (git-based) wrong"; sed 's/^/      /' /tmp/parallax_eg; fi
bash tests/t_finalize.sh >/tmp/parallax_fin 2>&1 && ok "completion receipt lands on feature/<slug> via worktree+CAS with \$ROOT detached (parallel-safe — v0.24 P1#3)" || { no "finalize on detached HEAD (P1#3)"; sed 's/^/      /' /tmp/parallax_fin; }
bash tests/t_immutable_oid.sh >/tmp/parallax_oid 2>&1 && ok "gate+push pin one immutable OID: pushing the OID sends the verified commit even after the ref moves (pushing the ref sends the moved tip — v0.25 P0#1)" || { no "immutable-OID gate/push (P0#1)"; sed 's/^/      /' /tmp/parallax_oid; }
{ grep -qF 'epic-gate.py --feature-ref "$VERIFIED_OID"' commands/run.md \
  && grep -qF 'VERIFIED_OID=$(git -C "$ROOT" rev-parse "$TIP_REF")' commands/run.md \
  && grep -qF 'push origin "$VERIFIED_OID:' commands/run.md \
  && grep -qF 'scripts/code-tree-hash.sh' commands/run.md \
  && grep -qF 'verified_tree' commands/run.md \
  && grep -qF 'slices.lock' commands/run.md \
  && grep -qF -- '--slug "$SLUG" --policy "$POLICY"' commands/run.md \
  && grep -qF 'update-ref "refs/heads/$TIP_REF"' commands/run.md \
  && ! grep -qF -- '--slices' commands/run.md \
  && ! grep -qF 'PARALLAX_VERIFIED' commands/run.md; } \
  && ok "run.md: gate+push use one pinned VERIFIED_OID; verified_tree + slices.lock + policy_hash wiring; worktree+CAS finalize (no --slices / PARALLAX_VERIFIED)" || no "run.md epic gate/finalize/OID not fully wired"
grep -qF 'is a feature-only license' commands/run.md && ok "run.md: warn = feature push only, never auto-advances the epic" || no "run.md missing warn=feature-only rule"

echo "[no_pyc]  (v0.24 P2 — no compiled bytecode is tracked/shipped)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  { ! git ls-files | grep -qE '(^|/)__pycache__/|\.py[co]$' && grep -qE '\*\.pyc' .gitignore; } && ok "no __pycache__/*.pyc tracked in git; .gitignore excludes them" || no "compiled bytecode tracked, or .gitignore missing *.pyc"
else
  { [ -z "$(find . -name '*.py[co]' 2>/dev/null)" ] && grep -qE '\*\.pyc' .gitignore; } && ok "no *.pyc in the shipped tree; .gitignore excludes them" || no "shipped tree contains *.pyc"
fi

echo "[resolution_gate]  (v0.31 P1 — EXECUTES resolution.py + epic-gate feature-state: one-time token, +1 generation, fail-closed set, stale-generation hold)"
bash tests/t_resolution_gate.sh >/tmp/parallax_rg 2>&1; rgrc=$?
if [ "$rgrc" = 2 ]; then echo "  · jsonschema not installed — resolution gate test skipped (the writer itself fails closed)";
elif [ "$rgrc" = 0 ]; then ok "resolution.py: schema-valid items only, single-use token, generation strictly +1, fail-closed (stale hash / reused token / empty diff / unclosed item / unsupported kind); epic-gate holds a non-complete or stale-generation feature"; else no "resolution gate (v0.31 P1) wrong"; sed 's/^/      /' /tmp/parallax_rg; fi
{ [ -f scripts/resolution.py ] && [ -f assets/feature-state.schema.json ] && [ -f assets/resolution-queue.schema.json ] && [ -f assets/resolution-receipt.schema.json ]; } && ok "v0.31 components present: resolution.py + feature-state/resolution-queue/resolution-receipt schemas" || no "v0.31 resolution components missing"

echo "[resolution_restart]  (v0.31 P2 — EXECUTES generation-restart.sh against REAL git repos: append-only restart, no old code on active paths, history archive, fast-forward publish, idempotency, atomic CAS race)"
bash tests/t_resolution_generation.sh >/tmp/parallax_rgen 2>&1; rgenrc=$?
if [ "$rgenrc" = 2 ]; then echo "  · jsonschema not installed — generation-restart test skipped (resolution.py is the real writer)";
elif [ "$rgenrc" = 0 ]; then ok "generation restart: fresh epic base + NO old impl on the active tree; old contract/run-state/reviews archived to history/generation-N/; gen-N+1 contract+feature-state+receipt installed; append-only fast-forward publish; idempotent re-run no-ops; stale expect-tip refuses (feature ref untouched)"; else no "generation-restart (v0.31 P2) wrong"; sed 's/^/      /' /tmp/parallax_rgen; fi
bash tests/t_resolution_race.sh >/tmp/parallax_rrace 2>&1; rracrc=$?
if [ "$rracrc" = 2 ]; then echo "  · jsonschema not installed — resolution race test skipped";
elif [ "$rracrc" = 0 ]; then ok "concurrent resolvers: the atomic feature-ref CAS lands EXACTLY ONE generation-2 restart; the loser refuses to clobber; the survivor is append-only (no force-push)"; else no "resolution race (v0.31 P2) wrong"; sed 's/^/      /' /tmp/parallax_rrace; fi
{ [ -f scripts/generation-restart.sh ] && ! grep -qE 'push[^|&]*(--force|-f )' scripts/generation-restart.sh; } && ok "scripts/generation-restart.sh present and never force-pushes (append-only by construction)" || no "generation-restart.sh missing or force-pushes"

echo "[resolution_migrate]  (v0.31 P3 — EXECUTES resolution.py migrate: v0.30 run-state -> gen-1 feature-state, idempotent, fail-closed)"
bash tests/t_resolution_migration.sh >/tmp/parallax_rmig 2>&1; rmigrc=$?
if [ "$rmigrc" = 2 ]; then echo "  · jsonschema not installed — migration test skipped";
elif [ "$rmigrc" = 0 ]; then ok "migrate: synthesizes a gen-1 feature-state + stamps run-state (feature_id/contract_generation); idempotent re-run; resolve-ready; fail-closed on a missing/garbled run-state"; else no "resolution migrate (v0.31 P3) wrong"; sed 's/^/      /' /tmp/parallax_rmig; fi

echo "[resolution_command]  (v0.31 P4 — /parallax:resolve drives safe-completion; producers emit STRUCTURED resolution items at a spec-gap park)"
{ [ -f commands/resolve.md ] && grep -q 'name: resolve' commands/resolve.md \
  && grep -qF 'resolution.py migrate' commands/resolve.md && grep -qF 'resolution.py apply' commands/resolve.md \
  && grep -qF 'generation-restart.sh' commands/resolve.md; } \
  && ok "resolve.md present; orchestrates migrate -> queue -> exact one-time token -> apply -> generation restart -> rebuild" \
  || no "commands/resolve.md missing or not wired to resolution.py/generation-restart.sh"
{ grep -qi 'choose-option' commands/resolve.md && grep -qi 'rescope' commands/resolve.md && grep -qi 'ship anyway' commands/resolve.md; } \
  && ok "resolve.md: only choose-option/custom-rule/rescope/abandon — no ignore/ship-anyway/manual-fixed" \
  || no "resolve.md missing the allowed-outcomes / no-ship-anyway boundary"
{ grep -qi 'anti-cheat' commands/resolve.md && grep -qi 'circuit-breaker' commands/resolve.md && grep -qiF 'refused' commands/resolve.md; } \
  && ok "resolve.md refuses non-contract parks (breaker/anti-cheat/code-fault/limit) and names the correct next path" \
  || no "resolve.md missing the unsupported-reason boundary"
{ grep -qF 'resolution.py add-item' commands/run.md && grep -q 'needs-resolution' commands/run.md; } \
  && ok "run.md: a spec-gap park records a structured resolution item + sets needs-resolution (queue is authoritative, not escalations.md)" \
  || no "run.md spec-gap park not wired to the resolution queue"
{ grep -qi 'competing readings' skills/role-arbiter/SKILL.md && grep -qi 'resolution-queue item' skills/role-arbiter/SKILL.md; } \
  && ok "role-arbiter emits a structured spec-gap (competing readings + spec refs + consequence) for the resolution queue" \
  || no "role-arbiter not wired for structured spec-gap items"
{ grep -qF '/parallax:resolve' commands/auto.md && grep -q 'needs-resolution' commands/auto.md; } \
  && ok "auto.md surfaces /parallax:resolve for a needs-resolution park and never self-resolves" \
  || no "auto.md missing the needs-resolution -> /parallax:resolve path"

echo "[affordance_review]  (v0.31 patch — /parallax:spec forces an Existing Affordance Review before approach choice; prompt-contract only: no new command/script/schema/state)"
{ grep -q "Existing Affordance Review" commands/spec.md \
  && grep -q "^## Existing affordance review" commands/spec.md \
  && grep -q "Thin overlay via an existing affordance" commands/spec.md \
  && grep -qF '`rejected`' commands/spec.md; } \
  && ok "spec.md: Step 3.5 review + frozen-spec 'Existing affordance review' section + thin-overlay-first approaches (a non-viable overlay is still shown as rejected)" \
  || no "spec.md affordance review / spec-format section / approach ordering not wired"
{ grep -q "always applies" commands/spec.md \
  && grep -q "without a recorded rejection of the plausible existing affordances" commands/spec.md; } \
  && ok "spec.md Step 8: always-applies affordance pass; a new subsystem with no recorded rejection is a spec blocker" \
  || no "spec.md missing the always-applies affordance self-review pass"
{ grep -qi "unjustified overbuild" commands/spec.md \
  && grep -qi "unjustified overbuild" skills/role-codex-judge/SKILL.md; } \
  && ok "pre-freeze reviewer scope (spec.md Step 9 + role-codex-judge) includes unjustified overbuild, classified high/medium/low by repo evidence" \
  || no "pre-freeze overbuild scope not wired into spec.md + role-codex-judge"
{ grep -q "never reshape the product" commands/spec.md \
  && grep -qi "not a line-count rule" commands/spec.md; } \
  && ok "spec.md: autonomous affordance choice is mechanical-only (a product-behaviour change parks/escalates); the thin-overlay heuristic is explicitly NOT a LOC gate" \
  || no "spec.md missing the autonomous boundary or the no-LOC-gate clause"
{ [ -f tests/affordance-eval-cases.md ] && [ "$(grep -cE '^### E[0-9]' tests/affordance-eval-cases.md)" -ge 5 ]; } \
  && ok "tests/affordance-eval-cases.md documents >= 5 prompt-level regression cases (E1..E6)" \
  || no "affordance eval cases missing or fewer than 5"
{ [ ! -e commands/affordance.md ] && ! ls scripts/ 2>/dev/null | grep -qi affordance && ! ls assets/ 2>/dev/null | grep -qi affordance; } \
  && ok "no new command/script/schema for affordance review — prompt-contract patch only (DESIGN §11)" \
  || no "affordance patch added a new command/script/schema (forbidden by §11)"

echo "[architecture_fitness]  (v0.32 — /parallax:spec adds an Architecture Fitness check before freeze; prompt-contract only, A1-A6 mapped to existing kinds, no new command/fanout)"
{ grep -q "Architecture Fitness (read-only" commands/spec.md \
  && grep -q "^## Architecture fitness" commands/spec.md \
  && grep -q "Architecture fitness pass (always applies)" commands/spec.md; } \
  && ok "spec.md: Step 4.5 Architecture Fitness + frozen-spec '## Architecture fitness' section + always-applies self-review pass" \
  || no "spec.md Architecture Fitness step/format/self-review not wired"
{ grep -qi 'architecture fitness' skills/role-codex-judge/SKILL.md && grep -qi 'never a defect' skills/role-codex-judge/SKILL.md; } \
  && ok "role-codex-judge: A1-A6 calibration with concrete consequence; style/preference never a defect (low non-blocking)" \
  || no "role-codex-judge Architecture Fitness calibration missing"
{ grep -qi 'public seam' skills/role-blind-coder/SKILL.md \
  && grep -qi 'regression seam' skills/role-test-writer/SKILL.md \
  && grep -qi 'regression seam' skills/role-arbiter/SKILL.md; } \
  && ok "role skills know the declared seam: blind-coder builds through the public seam, test-writer crosses the regression seam, arbiter confirms it post-green" \
  || no "role skills missing public/regression seam instructions"
{ [ -f tests/architecture-fitness-eval-cases.md ] && [ "$(grep -cE '^### F[0-9]' tests/architecture-fitness-eval-cases.md)" -ge 8 ]; } \
  && ok "tests/architecture-fitness-eval-cases.md documents >= 8 cases (F1..F9, incl. a style-only non-blocker + an allowed adapter)" \
  || no "architecture-fitness eval cases missing or < 8"
{ [ ! -e commands/architecture.md ]; } \
  && ok "no new /parallax:architecture command (Architecture Fitness is part of /parallax:spec)" \
  || no "a new architecture command was added (forbidden)"

echo "[project_scout]  (v0.33 — optional bounded Project Scout fanout inside /parallax:spec; internal read-only scouts, main verifies, linear default; no new command)"
{ grep -q "Project Scout Fanout (optional" commands/spec.md \
  && grep -q "Verify scout evidence before you rely on it" commands/spec.md \
  && grep -q "^## Project scout evidence" commands/spec.md; } \
  && ok "spec.md: optional Step 1.5 Project Scout Fanout + Step 1.6 main-agent verification rule + frozen-spec '## Project scout evidence' section" \
  || no "spec.md scout fanout step / verification rule / evidence section not wired"
{ [ -f skills/role-project-scout/SKILL.md ] \
  && grep -qi 'read-only' skills/role-project-scout/SKILL.md \
  && grep -qiE 'you decide nothing|decides nothing' skills/role-project-scout/SKILL.md \
  && grep -qiE 'never talk to the user|no questions' skills/role-project-scout/SKILL.md \
  && grep -qi 'confidence' skills/role-project-scout/SKILL.md && grep -qi 'uncertainty' skills/role-project-scout/SKILL.md; } \
  && ok "role-project-scout: read-only, decides nothing, never asks the user; report carries confidence + uncertainty + recommended verification" \
  || no "role-project-scout missing read-only/no-decision/report constraints"
{ [ -f agents/project-scout.md ] && grep -q 'role-project-scout' agents/project-scout.md && ! grep -qiE '^tools:.*(write|edit)' agents/project-scout.md; } \
  && ok "agents/project-scout.md loads role-project-scout and grants no Write/Edit tools (read-only by construction)" \
  || no "agents/project-scout.md missing, not loading the role, or granted write tools"
{ [ ! -e commands/scout.md ] && [ ! -e commands/project-scout.md ]; } \
  && ok "no public /parallax:scout command — fanout is pipeline-internal to /parallax:spec (TZ §4)" \
  || no "a public scout command was added (forbidden)"
{ [ -f tests/t_resolution_gate.sh ] && [ -f tests/t_resolution_generation.sh ] && [ -f tests/t_resolution_migration.sh ] && [ -f tests/architecture-fitness-eval-cases.md ]; } \
  && ok "v0.31 resolution tests + v0.32 architecture-fitness material preserved" \
  || no "v0.31/v0.32 test material missing after the v0.33 patch"
{ [ -f tests/project-scout-eval-cases.md ] && [ "$(grep -cE '^### Case [0-9]' tests/project-scout-eval-cases.md)" -ge 8 ]; } \
  && ok "tests/project-scout-eval-cases.md documents >= 8 scout cases (incl. small-repo + runtime-unavailable fallbacks, hallucination, overreach, resolve freshness)" \
  || no "project-scout eval cases missing or < 8"

echo "[intake_handoff]  (v0.34 — /parallax:spec --from-doc + /parallax:auto understand a Parallax Brief Packet; not-build-ready -> bounded Intake Response, never a guess; no new command)"
{ grep -qF 'Parallax Brief Packet' commands/spec.md \
  && grep -qF 'Intake Response' commands/spec.md \
  && grep -qiE 'input, not authority|is a \*\*hypothesis|hypothesis, not' commands/spec.md; } \
  && ok "spec.md: --from-doc accepts a Brief Packet; returns an Intake Response when not build-ready; proposed shape is a hypothesis, not authority" \
  || no "spec.md intake (brief packet / Intake Response / hypothesis) not wired"
{ grep -qF 'Existing Affordance Review' commands/spec.md && grep -qF 'Architecture Fitness' commands/spec.md; } \
  && ok "spec.md: intake still runs the Existing Affordance Review + Architecture Fitness (the brief never bypasses gates)" \
  || no "spec.md intake does not reaffirm the affordance/architecture gates"
{ grep -qF 'Intake Response' commands/auto.md && grep -qiE 'does NOT proceed|never starts .*parallax:run|stops and reports' commands/auto.md; } \
  && ok "auto.md stops on an Intake Response and does not start the build (no /parallax:run)" \
  || no "auto.md does not stop the build on an Intake Response"
{ [ -f references/parallax-brief-packet.md ] && grep -qF 'Intake Response' references/parallax-brief-packet.md; } \
  && ok "references/parallax-brief-packet.md present (Brief Packet template + Intake Response format + handoff etiquette)" \
  || no "references/parallax-brief-packet.md missing or incomplete"
{ grep -qiF 'ship anyway' commands/spec.md && grep -qiF 'no bypass' commands/spec.md; } \
  && ok "intake never offers ignore/ship-anyway — no gate bypass" \
  || no "spec.md intake bypass guard missing"
{ [ ! -e commands/intake.md ]; } \
  && ok "no public /parallax:intake command — intake reuses --from-doc / /parallax:auto (TZ §5)" \
  || no "a public intake command was added (forbidden)"
{ [ -f tests/t_resolution_gate.sh ] && [ -f tests/architecture-fitness-eval-cases.md ] && [ -f tests/project-scout-eval-cases.md ]; } \
  && ok "v0.31 resolution + v0.32 architecture + v0.33 project-scout test material preserved" \
  || no "prior-version test material missing after the v0.34 patch"
{ [ -f tests/intake-handoff-eval-cases.md ] && [ "$(grep -cE '^### Case [0-9]' tests/intake-handoff-eval-cases.md)" -ge 9 ]; } \
  && ok "tests/intake-handoff-eval-cases.md documents >= 9 cases (incl. bypass rejection, direct-prompt regression, loop bound)" \
  || no "intake eval cases missing or < 9"

echo "[eval_harness_v2]  (v0.35 — measurement release: the evaluation harness lives under bench/, NOT in the plugin; no new command, no runtime change)"
{ [ ! -e commands/eval.md ] && [ ! -e commands/benchmark.md ] && [ ! -e commands/measure.md ]; } \
  && ok "no public /parallax:eval | :benchmark | :measure command — measurement is out-of-runtime under bench/ (TZ §4/§5)" \
  || no "a public eval/benchmark/measure command was added (forbidden)"
{ [ -f references/evaluation-harness-v2.md ] && grep -qi 'measurement' references/evaluation-harness-v2.md; } \
  && ok "references/evaluation-harness-v2.md present and honest (measurement only, points to bench/)" \
  || no "references/evaluation-harness-v2.md missing or not honest"
{ grep -qiF 'evaluation harness v2' README.md && grep -qiF 'no command' README.md; } \
  && ok "README documents harness v2 as measurement-only (no new command, no benchmark claim)" \
  || no "README missing the honest harness-v2 note"

echo "[live_run_evidence_schema]  (v0.36 — the 4 evidence schemas validate + accept/reject samples)"
python3 - <<'PY' >/tmp/parallax_lre 2>&1
import json
try:
    import jsonschema
    from jsonschema import Draft202012Validator
except ImportError:
    print("SKIP"); raise SystemExit
def load(n): return json.load(open(f"assets/{n}.schema.json"))
for n in ["run-evidence", "run-evidence-event", "e2e-check", "defect-loop"]:
    Draft202012Validator.check_schema(load(n))
def good(doc, n):
    jsonschema.validate(doc, load(n)); return True
def rej(doc, n):
    try: jsonschema.validate(doc, load(n)); return False
    except jsonschema.ValidationError: return True
rev={"schema_version":"parallax-run-evidence-v1","plugin":{"name":"parallax","version":"0.36.1"},"run":{"run_id":"r","slug":"s","command_entry":"spec","started_at":"t","updated_at":"t","status":"frozen-spec"},"repo":{"root":"/x","branch":None,"base_tip":None,"feature_tip":None,"dirty_at_start":False,"dirty_at_end":False},"artifacts":{"spec":".parallax/s/spec.md","slices":None,"validation":None,"slices_lock":None,"run_state":None},"capabilities_exercised":{"existing_affordance_review":True,"architecture_fitness":True,"project_scout":False,"intake_handoff":True,"safe_resolution":False},"evidence_limits":["not a benchmark result"]}
ev={"schema_version":"parallax-run-evidence-event-v1","run_id":"r","slug":"s","at":"t","event_type":"spec_frozen","actor":"main","summary":"x","artifact_paths":{}}
e2e={"schema_version":"parallax-e2e-check-v1","run_id":"r","slug":"s","at":"t","check_id":"c","result":"pass","command":"npm run e2e"}
dl={"schema_version":"parallax-defect-loop-v1","run_id":"r","slug":"s","defect_id":"DL-1","found_at":"t","defect_kind":"trust","summary":"x","source_evidence":["log:1"],"spec_update":{"artifact":".parallax/s/spec.md","section":"A12","commit":None},"test_evidence":{"agent_type":None,"branch":None,"commit":None,"red_observed":True,"summary":"red"},"fix_evidence":{"agent_type":None,"branch":None,"commit":None,"summary":"fix"},"reverification":{"result":"not-run","artifact_paths":[]}}
checks=[
 good(rev,"run-evidence"), rej({**rev,"plugin":{"name":"parallax"}},"run-evidence"),
 rej({**rev,"repo":{}},"run-evidence"), rej({**rev,"artifacts":{}},"run-evidence"),
 rej({k:v for k,v in rev.items() if k!="capabilities_exercised"},"run-evidence"),
 rej({k:v for k,v in rev.items() if k!="evidence_limits"},"run-evidence"),
 rej({**rev,"run":{k:v for k,v in rev["run"].items() if k!="updated_at"}},"run-evidence"),
 good(ev,"run-evidence-event"), rej({**ev,"event_type":"made_up"},"run-evidence-event"),
 rej({k:v for k,v in ev.items() if k!="artifact_paths"},"run-evidence-event"),
 good(e2e,"e2e-check"), rej({"schema_version":"parallax-e2e-check-v1","run_id":"r","slug":"s","at":"t","check_id":"c","result":"pass"},"e2e-check"),
 good(dl,"defect-loop"), rej({k:v for k,v in dl.items() if k!="source_evidence"},"defect-loop"),
 rej({k:v for k,v in dl.items() if k!="fix_evidence"},"defect-loop"),
 rej({k:v for k,v in dl.items() if k!="reverification"},"defect-loop"),
]
print("OK" if all(checks) else "BAD "+str(checks))
PY
R=$(cat /tmp/parallax_lre)
if [ "$R" = SKIP ]; then echo "  · jsonschema not installed — evidence schema tests skipped";
elif [ "$R" = OK ]; then ok "run-evidence/event/e2e-check/defect-loop schemas valid; full minimum-shape samples pass; rejected: missing plugin.version, sparse repo:{} / artifacts:{}, missing capabilities_exercised / evidence_limits / run.updated_at, event without artifact_paths, unknown event_type, e2e pass-without-command, defect-loop without source_evidence / fix_evidence / reverification"; else no "evidence schema accept/reject wrong: $R"; fi

echo "[live_run_evidence_contract]"
{ for f in spec run auto resolve; do grep -q 'evidence/run-evidence.json' commands/$f.md || exit 1; done; grep -q 'plugin.version' commands/spec.md && grep -q 'plugin.version' commands/run.md; } \
  && ok "commands spec/run/auto/resolve all maintain .parallax/<slug>/evidence/run-evidence.json with plugin.version stamped" \
  || no "a command does not maintain run-evidence.json / plugin.version"

echo "[live_run_evidence_events]"
{ for f in spec run auto resolve; do grep -q 'events.jsonl' commands/$f.md || exit 1; done; grep -qi 'append-only' commands/run.md \
  && grep -q 'slice_dispatched' commands/run.md && grep -q 'arbiter_green' commands/run.md && grep -q 'verifier_pass' commands/run.md \
  && grep -q 'defect_found' commands/resolve.md && grep -q 'assumption_recorded' commands/resolve.md; } \
  && ok "append-only events.jsonl across commands; run.md emits slice/arbiter/verifier events; resolve.md emits defect_found + assumption_recorded" \
  || no "events.jsonl wiring incomplete"

echo "[live_run_evidence_no_public_command]"
{ [ ! -e commands/eval.md ] && [ ! -e commands/benchmark.md ] && [ ! -e commands/measure.md ] && [ ! -e commands/evidence.md ]; } \
  && ok "no public /parallax:eval|:benchmark|:measure|:evidence command (evidence is written by the existing commands)" \
  || no "a public evidence/eval command was added (forbidden by TZ §2)"

echo "[live_run_evidence_harness_candidate]"
{ [ -f references/live-run-evidence.md ] && grep -qi 'harness-record.candidate' references/live-run-evidence.md && grep -qi 'hidden.oracle' references/live-run-evidence.md && grep -qi 'transcript-derived' references/live-run-evidence.md; } \
  && ok "references/live-run-evidence.md: harness-record.candidate is a candidate (not a result); hidden_oracle null rule; transcript-derived labelled" \
  || no "live-run-evidence reference missing or incomplete"

echo "[live_run_evidence_defect_loop]"
{ [ -f assets/defect-loop.schema.json ] && grep -q 'defect-loop.jsonl' commands/resolve.md && grep -qi 'source_evidence' references/live-run-evidence.md; } \
  && ok "defect-loop schema present; resolve.md records the GPI A12 defect loop; reference documents mandatory source_evidence" \
  || no "defect-loop wiring incomplete"

echo "[live_run_evidence_claim_honesty]"
{ grep -qi 'auxiliary' skills/parallax-core/SKILL.md && grep -qi 'transcript' skills/parallax-core/SKILL.md \
  && grep -qiF 'auditability' README.md && grep -qiF 'not a benchmark' README.md; } \
  && ok "transcript is auxiliary provenance only (parallax-core); README frames v0.36 as auditability evidence, explicitly NOT a benchmark/quality claim" \
  || no "claim-honesty wiring missing (transcript-primary or no auditability/not-a-benchmark note)"

echo "[blindfold_guard]  (v0.37 P0.1 — EXECUTES blindfold-guard.py: the mechanical blindness wall)"
bash tests/t_blindfold.sh >/tmp/parallax_bf 2>&1 && ok "blindfold-guard.py rejects leaked impl/dist in the test worktree and leaked tests in the coder worktree; clean tracks pass (per wave, fail-closed)" || { no "blindfold guard (P0.1)"; sed 's/^/      /' /tmp/parallax_bf; }
grep -qF 'blindfold-guard.py' commands/run.md && ok "run.md dispatches blindfold-guard.py before each blind track and its done-gate (per wave)" || no "run.md does not wire blindfold-guard.py (P0.1)"
{ grep -qiF 'contamination' skills/role-arbiter/SKILL.md && grep -qiF 'natural-language fault' commands/run.md; } && ok "role-arbiter anti-cheat adds cross-worktree contamination; run.md redispatch carries only spec-anchored natural-language faults (no selectors/file:line/exports)" || no "contamination/redispatch wording missing (P0.1)"
grep -qiF 'baseline' skills/role-test-writer/SKILL.md && ok "role-test-writer brownfield rule: spec inlines the baseline / names a public fixture; never inspect impl or compiled output for expected values" || no "role-test-writer brownfield baseline guidance missing (P0.1)"

echo "[blindfold_monorepo]  (v0.37.3 F1 — EXECUTES blindfold-guard.py --scope-manifest against a REAL pnpm-style workspace)"
bash tests/t_blindfold_monorepo.sh >/tmp/parallax_bfm 2>&1; bfmrc=$?
if [ "$bfmrc" = 2 ] && grep -q SKIP /tmp/parallax_bfm; then echo "  · jsonschema not installed — monorepo blindfold execution test skipped (the guard itself fails closed)";
elif [ "$bfmrc" = 0 ]; then ok "slice-scoped mode: sibling src+dist + existing base tree pass on the test side while the slice's OWN new impl (and its own dist/) still fail closed — protected beats every allowlist; code side rejects the slice's own test file; .parallax/**/spec.md never a leak (strict AND scoped); bin/ not compiled by default but --compiled-glob 'bin/**' restores it; '**'/'**/*' dependency globs schema-rejected; slug mismatch + missing manifest = exit 3; t_blindfold.sh still green"; else no "blindfold monorepo mode (F1)"; sed 's/^/      /' /tmp/parallax_bfm; fi
{ [ -f assets/blindfold-scope.schema.json ] && grep -qF '"parallax-blindfold-scope-v1"' assets/blindfold-scope.schema.json; } && ok "assets/blindfold-scope.schema.json present (schema_version parallax-blindfold-scope-v1, slice-specific by construction)" || no "blindfold-scope.schema.json missing/wrong (F1)"
{ grep -qF -- '--scope-manifest' commands/run.md && grep -qF 'blindfold-scope.$SID.json' commands/run.md && grep -qF 'Monorepo dependency roots' commands/run.md; } && ok "run.md derives a per-slice scope manifest (protected paths from each track's committed diff, dep roots from validation.md) and passes --scope-manifest per wave — no whole-tree workaround" || no "run.md monorepo scope wiring missing (F1)"
grep -qF 'Monorepo dependency roots' commands/spec.md && ok "spec.md validation-contract format records the optional Monorepo dependency roots line (the manifest's source)" || no "spec.md Monorepo dependency roots line missing (F1)"
python3 - <<'PY' && ok "blindfold-guard.py source safeguards: bin/ out of the default compiled alternation; .parallax/ is shared surface; strict-only impl heuristic is scope-gated" || no "blindfold-guard.py source safeguards missing (F1)"
import re
src = open('scripts/blindfold-guard.py').read()
m = re.search(r'_COMPILED_DIR = re\.compile\(\s*\n?\s*r"([^"]+)"', src)
assert m and '|bin|' not in m.group(1) and '(bin|' not in m.group(1) and '|bin)' not in m.group(1), m and m.group(1)
assert '_SHARED_DIR' in src and re.search(r'_SHARED_DIR\s*=\s*re\.compile\(r"[^"]*parallax', src)
assert 'protected_impl' in src and 'protected_test' in src and 'dependency_allow_globs' in src
assert 'scope is None and (not is_test)' in src   # base tree visible by design in scoped mode
PY

echo "[merge_ledger_path_drift]  (v0.37.3 F4 — EXECUTES merge-ledger.py --repo-root against a REAL git repo)"
bash tests/t_merge_ledger_path_drift.sh >/tmp/parallax_mlpd 2>&1 && ok "path drift: a basename/sub-path echo of round-1's repo-relative path binds to the SAME finding (resolve settles it, re-report regresses it — no phantom duplicate); an ambiguous basename stays distinct with loud path_warnings (never silently merged, never closes the wrong finding); bad --repo-root = exit 3, no silent fallback; cited-id consistency intact; legacy no-flag behavior unchanged" || { no "merge-ledger path drift (F4)"; sed 's/^/      /' /tmp/parallax_mlpd; }
grep -qF -- '--repo-root "$ASSEMBLED"' commands/run.md && ok "run.md passes --repo-root \$ASSEMBLED to merge-ledger.py, anchoring fingerprints to the reviewed tree's tracked files" || no "run.md merge-ledger --repo-root wiring missing (F4)"

echo "[run_phase_evidence_events]  (v0.37.3 F5 — EXECUTES evidence-event.py: the build phase leaves a first-class timeline, not a spec_frozen stub)"
bash tests/t_evidence_events_run_phase.sh >/tmp/parallax_evre 2>&1; evrerc=$?
if [ "$evrerc" = 2 ] && grep -q SKIP /tmp/parallax_evre; then echo "  · jsonschema not installed — run-phase evidence execution test skipped (the helper itself fails closed)";
elif [ "$evrerc" = 0 ]; then ok "helper appends a schema-valid build timeline (slice_dispatched, arbiter_iteration_started/finished, codex_round_started/finished, slice_green, run_completed — every line independently re-validated); run-evidence.json moves frozen-spec -> running -> complete; append-only holds byte-for-byte; unknown event type / run_id mismatch / invalid status / missing run-evidence all refused with nothing written"; else no "run-phase evidence events (F5)"; sed 's/^/      /' /tmp/parallax_evre; fi
python3 - <<'PY' && ok "run-evidence-event schema carries all 9 F5 build-phase types, prior types kept (additive only)" || no "event schema missing F5 types (F5)"
import json
e = set(json.load(open('assets/run-evidence-event.schema.json'))["properties"]["event_type"]["enum"])
new = {"arbiter_iteration_started","arbiter_iteration_finished","codex_round_started","codex_round_finished",
       "slice_green","pr_opened","pr_merged","session_handoff","feature_merged"}
old = {"intake_received","intake_response","spec_frozen","slice_dispatched","test_writer_red","blind_coder_done",
       "arbiter_green","arbiter_red","verifier_pass","verifier_concerns","run_completed","run_parked","failed_infra"}
assert new <= e, new - e
assert old <= e, old - e
PY
{ grep -qF 'scripts/evidence-event.py' commands/run.md && grep -qF 'update-run' commands/run.md \
  && grep -qF 'arbiter_iteration_started' commands/run.md && grep -qF 'codex_round_started' commands/run.md \
  && grep -qF 'slice_green' commands/run.md && grep -qF 'session_handoff' commands/run.md \
  && grep -qF 'feature_merged' commands/run.md && grep -qF -- '--status running' commands/run.md; } \
  && ok "run.md writes Phase 2-5 events THROUGH the helper at dispatch/red/done/arbiter-iteration/codex-round/green/pause/park/terminal/PR-merge points, and moves run.status off frozen-spec at preflight" \
  || no "run.md run-phase event wiring incomplete (F5)"
{ grep -qF 'human-authorized' commands/run.md && grep -qF 'self-continued' commands/run.md; } \
  && ok "verifier-round events record human-authorized vs self-continued as distinct facts (P2)" || no "round-authorization distinction missing (P2)"
{ grep -qiF 'not captured by this run' commands/run.md || grep -qiF 'evidence_limits' commands/run.md && grep -qiF 'factual' commands/run.md; } \
  && ok "evidence_limits wording stays factual — no categorical 'transcript unavailable' claims when the path exists (P2)" || no "evidence_limits honesty wording missing (P2)"

echo "[ui_reachability]  (v0.37.3 F2 — directive: a user-reachable frontend seam needs interaction proof, not router membership)"
{ grep -qiF 'user-reachable' skills/role-arbiter/SKILL.md && grep -qiF 'interaction' skills/role-arbiter/SKILL.md \
  && grep -qiF 'destination content appears' skills/role-arbiter/SKILL.md && grep -qiF 'no interaction harness available' skills/role-arbiter/SKILL.md; } \
  && ok "role-arbiter: reachability classes set the proof bar; membership insufficient for user-reachable; harness-present-but-no-proof routes as test/code-fault; no-harness -> recorded limitation + cross-model verifier inspects" \
  || no "role-arbiter user-reachability rule missing (F2)"
{ grep -qiF 'user-reachable' skills/role-test-writer/SKILL.md && grep -qiF 'stale route-membership' skills/role-test-writer/SKILL.md; } \
  && ok "role-test-writer: never reuse a stale route-membership test where the spec demands user reachability — write a fresh interaction test" \
  || no "role-test-writer stale-route-test rule missing (F2)"
{ grep -qF 'internal/import-only' commands/spec.md && grep -qF 'route-registered' commands/spec.md && grep -qiF 'user-reachable' commands/spec.md; } \
  && ok "spec.md slice manifest marks each frontend seam internal/import-only | route-registered | user-reachable" \
  || no "spec.md seam reachability classes missing (F2)"
grep -qiF 'user-reachable' commands/run.md && ok "run.md arbiter dispatch carries the user-reachability proof requirement" || no "run.md dispatch reachability wording missing (F2)"
{ [ -f tests/frontend-reachability-eval-cases.md ] && grep -qiF 'tab' tests/frontend-reachability-eval-cases.md \
  && grep -qiF 'must NOT be green' tests/frontend-reachability-eval-cases.md \
  && grep -qiF 'import-only' tests/frontend-reachability-eval-cases.md \
  && grep -qiF 'destination content appears' tests/frontend-reachability-eval-cases.md; } \
  && ok "frontend-reachability eval fixture present: hidden-tab must-not-green, click-through acceptable, import-only smoke import suffices (+ stale-test and no-harness cases)" \
  || no "frontend reachability eval cases missing/incomplete (F2)"

echo "[provider_transport]  (v0.37.3 F6/P1 — EXECUTES strip-openai-schema.py; canonical codex exec is hang-proof; timeout != rate limit)"
STMP=$(mktemp -d)
python3 scripts/strip-openai-schema.py assets/codex/review-round.schema.json "$STMP/rr.openai.json" >/tmp/parallax_strip 2>&1 \
  && python3 - "$STMP/rr.openai.json" <<'PY' && ok "review-round provider copy: top-level allOf stripped for the CALL, full schema intact and still rejects a verdict/findings-inconsistent response (the stripped copy is never the acceptance bar)" || no "strip-openai-schema.py behavior wrong (F6)"
import json, sys, jsonschema
stripped = json.load(open(sys.argv[1]))
assert "allOf" not in stripped, "top-level allOf still present in the provider copy"
full = json.load(open('assets/codex/review-round.schema.json'))
assert "allOf" in full, "full schema lost its allOf (must stay untouched)"
bad = {"verdict": "pass", "findings": [{"severity": "high", "kind": "spec-gap", "spec_ref": "B1",
        "where": "x.ts:1", "claim": "c", "evidence": "e"}]}
jsonschema.validate(bad, stripped)          # the weaker call copy admits it…
try:
    jsonschema.validate(bad, full); raise SystemExit("full schema failed to reject inconsistency")
except jsonschema.ValidationError:
    pass                                     # …the FULL schema still rejects it
PY
rm -rf "$STMP"
{ grep -qF 'codex exec' skills/role-codex-judge/SKILL.md && grep -qF '< /dev/null' skills/role-codex-judge/SKILL.md; } \
  && ok "role-codex-judge canonical codex exec ends in < /dev/null (stdin hang closed at the wrapper, not remembered per prompt)" \
  || no "canonical codex exec missing < /dev/null (F6)"
grep -qF 'strip-openai-schema.py' skills/role-codex-judge/SKILL.md \
  && ok "role-codex-judge routes allOf schemas through the stripped provider copy and validates the RESPONSE against the full schema" \
  || no "role-codex-judge allOf schema-copy path missing (F6)"
{ grep -qiF 'empty stdout' skills/role-codex-judge/SKILL.md && grep -qiF 'NOT a rate limit' skills/role-codex-judge/SKILL.md; } \
  && ok "provider error classification: timeout with empty stdout/stderr is a hang, never reported as a rate limit" \
  || no "timeout-vs-limit classification missing (F6)"

echo "[finalize_freshness]  (v0.37 P0.2 + v0.37.1 — EXECUTES finalize-gate.py: terminal completion receipt bound to committed evidence)"
bash tests/t_finalize_gate.sh >/tmp/parallax_fg 2>&1; fgrc=$?
if [ "$fgrc" = 2 ]; then echo "  · jsonschema not installed — finalize-gate execution test skipped";
elif [ "$fgrc" = 0 ]; then ok "finalize-gate.py finalizes only a self-consistent terminal bundle; HOLDS on: no completion receipt (updated_at-only), non-ISO timestamp, run-evidence run_id mismatch, missing run_completed event, evidence byte-tamper (sha256!=completion), verified_tree!=code-tree-hash, missing arbiter receipt, missing evidence, green-unverified — deep checks still delegated to epic-gate.py"; else no "finalize-gate.py (git-based freshness) wrong"; sed 's/^/      /' /tmp/parallax_fg; fi
grep -qF 'finalize-gate.py' commands/run.md && ok "run.md runs the standalone finalize-gate.py before feature push / epic advance (not only orchestrator Step 4)" || no "run.md does not wire finalize-gate.py (P0.2)"
{ grep -qiF 'green-unverified' commands/run.md && grep -qiF 'no-codex' commands/run.md; } && ok "run.md documents verifier-limited continuation (build to green-unverified, integrate only when drained) + loud no-codex degradation for trust/anti-cheat/money/PII/security specs" || no "run.md verifier-limited / no-codex wording missing (P0.2)"

echo "[feature_sweep]  (v0.37 P0.3 — EXECUTES feature-sweep.py: whole-feature invariant sweep)"
bash tests/t_feature_sweep.sh >/tmp/parallax_fs 2>&1 && ok "feature-sweep.py catches a cross-file PII serialization a per-slice green misses, honours the explicit mock-only stamp, and fails closed on a missing invariants manifest" || { no "feature sweep (P0.3)"; sed 's/^/      /' /tmp/parallax_fs; }
{ grep -qiF 'prohibition' commands/spec.md && grep -qF 'invariants.json' commands/spec.md; } && ok "spec.md adds the prohibition-reconciliation substep recording .parallax/<slug>/invariants.json (what must NOT be violated, not only what to reuse)" || no "spec.md prohibition-reconciliation substep missing (P0.3)"
grep -qiF 'live-consumer' skills/role-arbiter/SKILL.md && ok "role-arbiter requires live-consumer proof for a new/changed shared-contract field (a unit-test mention is not coverage)" || no "role-arbiter live-consumer rule missing (P0.3)"

echo "[contract_amend]  (v0.37 P0.4 — EXECUTES contract-amend.py: auditable frozen-contract tightening)"
bash tests/t_contract_amend.sh >/tmp/parallax_ca 2>&1 && ok "contract-amend.py rejects an in-place post-freeze edit, accepts a sanctioned mechanical-tightening chain (prev->new hash, propagation all-true, pre-freeze pass), and rejects incomplete propagation" || { no "contract amend (P0.4)"; sed 's/^/      /' /tmp/parallax_ca; }
{ grep -qF 'contract-amend.py' commands/run.md || grep -qF 'contract-amend.py' commands/resolve.md; } && ok "the sanctioned tightening path is wired into an existing command (run.md/resolve.md) — no new public command" || no "contract-amend.py not wired into an existing command (P0.4)"

echo "[governance_evidence_required]  (v0.37 P1.5 — finalize needs committed evidence + a session lease)"
{ grep -qiF 'evidence' commands/run.md && grep -qiF 'lease' commands/run.md; } && ok "run.md requires committed evidence at finalize and a session lease/ownership before resume/advance" || no "run.md evidence-required / lease wording missing (P1.5)"

echo "[finalize_push_order]  (v0.37.2 — the remote feature push must be GATED: finalize-gate.py runs BEFORE the feature push)"
FG_LINE=$(grep -n -F 'scripts/finalize-gate.py --feature-ref "$VERIFIED_OID" --slug "$SLUG"' commands/run.md | head -1 | cut -d: -f1)
PUSH_LINE=$(grep -n -F 'git -C "$ROOT" push origin "$VERIFIED_OID:refs/heads/$TIP_REF"' commands/run.md | head -1 | cut -d: -f1)
{ [ -n "$FG_LINE" ] && [ -n "$PUSH_LINE" ] && [ "$FG_LINE" -lt "$PUSH_LINE" ] && grep -qF 'feature NOT pushed' commands/run.md; } \
  && ok "run.md runs finalize-gate.py (line $FG_LINE) BEFORE the feature-branch push (line $PUSH_LINE); the finalize hold says 'feature NOT pushed' (v0.37.2 gate-before-push)" \
  || no "run.md finalization order wrong: finalize-gate (line ${FG_LINE:-none}) must precede the feature push (line ${PUSH_LINE:-none}) and the finalize hold must say 'feature NOT pushed'"

echo "[security_no_secrets]  (locks repo hygiene)"
grep -qE 'sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,}|[0-9]{6,}:[A-Za-z0-9_-]{20,}' assets/codex/codex.toml.example && no "config has a secret-shaped value" || ok "config has no secret-shaped values (only *_env names)"
{ [ -f SECURITY.md ] && grep -q '^\.env$' .gitignore; } && ok "SECURITY.md + .gitignore (.env) present" || no "SECURITY.md/.gitignore missing"

echo "[cloud_setup]  (real install attempts, not commented-out — locks #6)"
grep -qE '^\s*command -v codex .*\|\| npm i -g' scripts/cloud-setup.sh && ok "cloud-setup.sh actually ATTEMPTS the CLI installs (uncommented)" || no "cloud-setup.sh installs are still commented out"
grep -qiE 'best-effort|adjust the package names' README.md && ok "README is honest about best-effort installs" || no "README overclaims that setup installs"

echo "[release_coherence]  (v0.37.3 — manifest/changelog/docs agree on the release; v0.31-v0.37.2 kept)"
{ grep -q '"version": "0.37.3"' .claude-plugin/plugin.json \
  && grep -q '^## 0.37.3' CHANGELOG.md \
  && grep -q '^## 0.37.2' CHANGELOG.md \
  && grep -q '^## 0.37.1' CHANGELOG.md \
  && grep -q '^## 0.37.0' CHANGELOG.md \
  && grep -q '^## 0.36.1' CHANGELOG.md \
  && grep -q '^## 0.31.0' CHANGELOG.md \
  && grep -qiF 'reliability hardening' README.md \
  && grep -qiF 'monorepo' README.md \
  && grep -qiF 'user-reachab' README.md \
  && grep -qiF 'runtime governance' README.md \
  && grep -qiF 'live-run evidence' README.md \
  && grep -qF '/parallax:resolve' README.md \
  && grep -qiF 'completion' README.md \
  && [ -f references/runtime-governance.md ] \
  && [ -f references/live-run-evidence.md ] \
  && [ -f references/live-run-audit-findings.md ] \
  && [ -f scripts/blindfold-guard.py ] && [ -f scripts/finalize-gate.py ] \
  && [ -f scripts/feature-sweep.py ] && [ -f scripts/contract-amend.py ] \
  && [ -f scripts/evidence-event.py ] && [ -f scripts/strip-openai-schema.py ] \
  && [ -f assets/blindfold-scope.schema.json ]; } \
  && ok "version 0.37.3 in plugin.json; CHANGELOG has 0.37.3 (0.37.2/0.37.1/0.37.0/0.36.1/0.31.0 kept); README covers live-run reliability hardening (monorepo blindfold, closure, path-stable ledger, run-phase events, UI reachability) + prior boundaries; audit-findings reference + new scripts/schema present" \
  || no "release coherence: version/changelog/docs not aligned for 0.37.3"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
