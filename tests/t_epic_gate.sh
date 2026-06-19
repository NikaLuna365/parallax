#!/usr/bin/env bash
# v0.24 P0#1/P0#2/P1#3 regression — EXECUTES scripts/epic-gate.py against REAL git repos. The gate is a
# feature-level receipt bound to the promoted commit: it reads run-state + ledgers via `git show <ref>:…`,
# requires status=complete with every slice integrated, checks each ledger's identity + rounds_used>=1 +
# GREEN triage, and requires run-state.verified_tree == the recomputed code-tree hash of the commit.
# Exit: 0 all scenarios behaved, 2 SKIP (no jsonschema — the gate validates fail-closed), 1 a scenario wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }

python3 - "$PLUGIN" <<'PY'
import json,os,subprocess,sys,tempfile
PLUGIN=sys.argv[1]
TOML=os.path.join(PLUGIN,"assets/codex/codex.toml.example")
GATE=os.path.join(PLUGIN,"scripts/epic-gate.py"); TH=os.path.join(PLUGIN,"scripts/code-tree-hash.sh")
def sh(*a): return subprocess.run(a,capture_output=True,text=True)
def newrepo():
    R=tempfile.mkdtemp(); sh("git","init","-q",R)
    sh("git","-C",R,"config","user.email","t@t"); sh("git","-C",R,"config","user.name","t")
    os.makedirs(os.path.join(R,"src")); os.makedirs(os.path.join(R,".parallax/demo/reviews"))
    open(os.path.join(R,"src/a.ts"),"w").write("code\n"); return R
def wl(R,sid,**o):
    d={"slug":"demo","slice_id":sid,"rounds_used":1,"findings":[]}; d.update(o)
    open(os.path.join(R,f".parallax/demo/reviews/{sid}.json"),"w").write(json.dumps(d))
def wrs(R,slices,status="complete",vt=None):
    rs={"run_id":"r","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":status,
        "slices":slices,"integrated":[s["id"] for s in slices],"updated_at":"t"}
    if status=="running": rs["lock"]={"holder":"r","acquired_at":"t","expires_at":"t2"}
    if vt is not None: rs["verified_tree"]=vt
    open(os.path.join(R,".parallax/demo/run-state.json"),"w").write(json.dumps(rs))
def commit(R,m): sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m",m)
def codehash(R): return sh("bash",TH,"HEAD",R).stdout.strip()
def gate(R): return sh("python3",GATE,"--feature-ref","HEAD","--slug","demo","--policy",TOML,"--repo",R).returncode

def scenario(slices, mutate=None, ledger_extra=None, status="complete"):
    R=newrepo()
    for s in slices:
        if not (ledger_extra and s["id"] in ledger_extra and ledger_extra[s["id"]] is None):
            wl(R,s["id"], **((ledger_extra or {}).get(s["id"]) or {}))
    wrs(R,slices,status=status,vt="0"*40); commit(R,"code+ledgers")
    vt=codehash(R); wrs(R,slices,status=status,vt=vt); commit(R,"complete")
    if mutate: mutate(R);
    return gate(R)

def code_change(R): open(os.path.join(R,"src/a.ts"),"w").write("CHANGED\n"); commit(R,"sneaky code change")

I=[{"id":"S1","status":"integrated"}]; II=[{"id":"S1","status":"integrated"},{"id":"S2","status":"integrated"}]
cases={
 "happy"                 : (scenario(II), 0),
 "code-changed-after"    : (scenario(I, mutate=code_change), 1),
 "missing-ledger"        : (scenario(II, ledger_extra={"S2":None}), 1),   # S2 listed integrated, ledger never written/committed
 "parked-slice"          : (scenario([{"id":"S1","status":"integrated"},{"id":"S2","status":"parked","parked_reason":"spec-gap"}]), 1),
 "identity-mismatch"     : (scenario(II, ledger_extra={"S2":{"slice_id":"S1"}}), 1),
 "rounds_used=0"         : (scenario(I, ledger_extra={"S1":{"rounds_used":0}}), 1),
 "status!=complete"      : (scenario(I, status="running"), 1),
}
bad={k:v for k,(v,want) in cases.items() if v!=want}
print("t_epic_gate OK" if not bad else "FAIL "+json.dumps({k:cases[k][0] for k in bad}))
sys.exit(0 if not bad else 1)
PY
