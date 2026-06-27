#!/usr/bin/env bash
# v0.37 P0.2 — EXECUTES scripts/finalize-gate.py. Builds an epic-gate-PASSING committed feature
# (frozen contract, committed strict policy, per-slice verifier ledgers, verified_tree, frozen
# slice-set) and then checks the NEW standalone finalize requirements:
#   * every slice carries a committed, schema-valid green arbiter receipt (no self-greened slice);
#   * required evidence artifacts are committed (run-evidence.json + events.jsonl);
#   * no slice is green-unverified (owed cross-model verification must be drained);
#   * run-state is fresh (updated_at present).
# The complete set finalizes (0); removing any single requirement holds finalize (1).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }
python3 - "$PLUGIN" <<'PY'
import json,os,subprocess,sys,tempfile
PLUGIN=sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN,"scripts")); import triage as T
TOML=os.path.join(PLUGIN,"assets/codex/codex.toml.example")
FG=os.path.join(PLUGIN,"scripts/finalize-gate.py")
TH=os.path.join(PLUGIN,"scripts/code-tree-hash.sh"); CH=os.path.join(PLUGIN,"scripts/contract-hash.sh")
PHASH=T.policy_hash(T.load_policy(TOML)[0])
VD={"S1":"aaaaaaa","S2":"bbbbbbb"}
def sh(*a): return subprocess.run(a,capture_output=True,text=True)

def build(arbiter=True, evidence=True, gu=False, fresh=True):
    R=tempfile.mkdtemp(); sh("git","init","-q",R)
    sh("git","-C",R,"config","user.email","t@t"); sh("git","-C",R,"config","user.name","t")
    os.makedirs(R+"/src"); os.makedirs(R+"/.parallax/demo/reviews")
    os.makedirs(R+"/.parallax/demo/arbiter"); os.makedirs(R+"/.parallax/demo/evidence")
    open(R+"/src/a.ts","w").write("code\n")
    open(R+"/.parallax/codex.toml","w").write(open(TOML).read())
    open(R+"/.parallax/demo/spec.md","w").write("spec: tax HALF_UP\n")
    open(R+"/.parallax/demo/slices.md","w").write("S1, S2\n")
    open(R+"/.parallax/demo/validation.md","w").write("full: npm test\n")
    json.dump({"slug":"demo","slices":["S1","S2"]}, open(R+"/.parallax/demo/slices.lock","w"))
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","frozen")
    vt=sh("bash",TH,"HEAD",R).stdout.strip(); ch=sh("bash",CH,"HEAD","demo",R).stdout.strip()
    for sid in ("S1","S2"):
        json.dump({"slug":"demo","slice_id":sid,"rounds_used":1,"policy_hash":PHASH,"contract_hash":ch,"findings":[]},
                  open(f"{R}/.parallax/demo/reviews/{sid}.json","w"))
        if arbiter:
            json.dump({"schema_version":"parallax-arbiter-receipt-v1","slug":"demo","slice_id":sid,
                       "arbiter":"arbiter-1","verdict":"green","verified_diff":VD[sid]},
                      open(f"{R}/.parallax/demo/arbiter/{sid}.json","w"))
    if evidence:
        json.dump({"schema_version":"parallax-run-evidence-v1"}, open(R+"/.parallax/demo/evidence/run-evidence.json","w"))
        open(R+"/.parallax/demo/evidence/events.jsonl","w").write("{}\n")
    s1 = {"id":"S1","status":"green-unverified" if gu else "integrated","verified_diff":VD["S1"]}
    if gu: s1.update({"arbiter_verdict":"green","wave_base":"a"*40})
    rs={"run_id":"r","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":"complete","verified_tree":vt,
        "slices":[s1,{"id":"S2","status":"integrated","verified_diff":VD["S2"]}],
        "integrated":["S1","S2"],"updated_at":("t" if fresh else "")}
    json.dump(rs, open(R+"/.parallax/demo/run-state.json","w"))
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","complete")
    return R
def fg(R): return sh("python3",FG,"--feature-ref","HEAD","--slug","demo","--repo",R).returncode

cases={
 "happy":            (fg(build()), 0),
 "no-arbiter":       (fg(build(arbiter=False)), 1),
 "no-evidence":      (fg(build(evidence=False)), 1),
 "green-unverified": (fg(build(gu=True)), 1),
 "stale-runstate":   (fg(build(fresh=False)), 1),
}
bad={k:v[0] for k,v in cases.items() if v[0]!=v[1]}
print("t_finalize_gate OK" if not bad else "FAIL "+json.dumps(bad))
sys.exit(0 if not bad else 1)
PY
