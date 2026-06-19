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
r=d['review']; assert r['max_rounds']==2 and r['resume_codex_session'] is False and r['recheck_fixed'] is True
assert r['block_severities']==["medium","high"] and r['advisory_severities']==["low"]
assert set(r['always_block_kinds'])=={"safety","anti-cheat","spec-gap"}, r['always_block_kinds']
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
{ grep -q "scripts/merge-ledger.py" commands/run.md && grep -qF "scripts/triage.py \"\$LEDGER\" --policy .parallax/codex.toml" commands/run.md && grep -q "reviews/\$SID.json" commands/run.md; } && ok "run.md wires merge-ledger + triage(--policy from toml) + per-slice ledger" || no "run.md missing producer-proof pipeline"
grep -q "never checked out in parallel" commands/run.md && ok "run.md: feature branch not checked out in parallel (no stale worktree on CAS)" || no "run.md missing no-checkout-in-parallel"

echo "[reviewed_commit]  (v0.23 P0#1 + P1#5 — EXECUTES: commit == reviewed tree + receipt; scoped guard ignores the ledger)"
bash tests/t_difftree.sh >/tmp/parallax_dt 2>&1 && ok "reviewed-content hash tracks code (not HEAD^{tree}); scoped guard ignores a tracked ledger (P1#5); receipt-only add keeps untracked files out (P0#1)" || { no "reviewed commit / scoped guard (P0#1/P1#5)"; sed 's/^/      /' /tmp/parallax_dt; }
{ grep -qF 'git -C "$ASSEMBLED" ls-files -s' commands/run.md \
  && grep -qF 'git hash-object --stdin' commands/run.md \
  && grep -qF 'git -C "$ASSEMBLED" diff --quiet -- "${SRC_PATHSPECS[@]}"' commands/run.md \
  && grep -qF 'git -C "$ASSEMBLED" add -- "$LEDGER"' commands/run.md \
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

echo "[epic_gate]  (v0.24 P0#1/P0#2/P1#3 — EXECUTES epic-gate.py against REAL git repos: a feature-level receipt bound to the promoted commit)"
bash tests/t_epic_gate.sh >/tmp/parallax_eg 2>&1; egrc=$?
if [ "$egrc" = 2 ]; then echo "  · jsonschema not installed — epic-gate execution test skipped";
elif [ "$egrc" = 0 ]; then ok "epic-gate.py: verified only for a committed, complete run whose verified_tree matches the promoted commit; code-changed-after-review / uncommitted-or-missing ledger / parked slice / identity-mismatch / rounds_used<1 / status!=complete => hold"; else no "epic-gate.py (git-based) wrong"; sed 's/^/      /' /tmp/parallax_eg; fi
{ grep -qF 'epic-gate.py --feature-ref' commands/run.md \
  && grep -qF 'scripts/code-tree-hash.sh' commands/run.md \
  && grep -qF 'verified_tree' commands/run.md \
  && ! grep -qF -- '--slices' commands/run.md \
  && ! grep -qF 'PARALLAX_VERIFIED' commands/run.md; } \
  && ok "run.md gates the epic push on epic-gate.py --feature-ref + records the verified_tree receipt (no --slices, no PARALLAX_VERIFIED)" || no "run.md epic gate not wired to the committed-feature-ref gate"
grep -qF 'is a feature-only license' commands/run.md && ok "run.md: warn = feature push only, never auto-advances the epic" || no "run.md missing warn=feature-only rule"

echo "[no_pyc]  (v0.24 P2 — no compiled bytecode is tracked/shipped)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  { ! git ls-files | grep -qE '(^|/)__pycache__/|\.py[co]$' && grep -qE '\*\.pyc' .gitignore; } && ok "no __pycache__/*.pyc tracked in git; .gitignore excludes them" || no "compiled bytecode tracked, or .gitignore missing *.pyc"
else
  { [ -z "$(find . -name '*.py[co]' 2>/dev/null)" ] && grep -qE '\*\.pyc' .gitignore; } && ok "no *.pyc in the shipped tree; .gitignore excludes them" || no "shipped tree contains *.pyc"
fi

echo "[security_no_secrets]  (locks repo hygiene)"
grep -qE 'sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,}|[0-9]{6,}:[A-Za-z0-9_-]{20,}' assets/codex/codex.toml.example && no "config has a secret-shaped value" || ok "config has no secret-shaped values (only *_env names)"
{ [ -f SECURITY.md ] && grep -q '^\.env$' .gitignore; } && ok "SECURITY.md + .gitignore (.env) present" || no "SECURITY.md/.gitignore missing"

echo "[cloud_setup]  (real install attempts, not commented-out — locks #6)"
grep -qE '^\s*command -v codex .*\|\| npm i -g' scripts/cloud-setup.sh && ok "cloud-setup.sh actually ATTEMPTS the CLI installs (uncommented)" || no "cloud-setup.sh installs are still commented out"
grep -qiE 'best-effort|adjust the package names' README.md && ok "README is honest about best-effort installs" || no "README overclaims that setup installs"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
