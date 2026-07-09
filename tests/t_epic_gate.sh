#!/usr/bin/env bash
# EXECUTES scripts/epic-gate.py against REAL git repos. The gate is a feature-level receipt bound to the
# promoted commit: it reads run-state, slices.lock, every ledger, the [review] policy AND the frozen spec
# contract via `git show <ref>:…`, and verifies status=complete + slug identity + exact frozen slice-set +
# all integrated + per-ledger (slug/slice_id identity, policy_hash == committed policy, contract_hash ==
# committed spec contract, rounds_used>=1, GREEN triage) + verified_tree == recomputed code-tree hash.
# Exit: 0 all scenarios behaved, 2 SKIP (no jsonschema — gate validates fail-closed), 1 a scenario wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }

python3 - "$PLUGIN" <<'PY'
import json,os,subprocess,sys,tempfile
PLUGIN=sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN,"scripts")); import triage as T
TOML=os.path.join(PLUGIN,"assets/codex/codex.toml.example")
GATE=os.path.join(PLUGIN,"scripts/epic-gate.py")
TH=os.path.join(PLUGIN,"scripts/code-tree-hash.sh"); CH=os.path.join(PLUGIN,"scripts/contract-hash.sh")
PHASH=T.policy_hash(T.load_policy(TOML)[0])
PERM='[review]\nmax_rounds=2\nblock_severities=[]\nadvisory_severities=["low","medium","high"]\nalways_block_kinds=[]\n'
def sh(*a): return subprocess.run(a,capture_output=True,text=True)

def build(slices_lock=("S1","S2"), rs_slices=None, ledgers=None, status="complete", mutate=None):
    R=tempfile.mkdtemp(); sh("git","init","-q",R)
    sh("git","-C",R,"config","user.email","t@t"); sh("git","-C",R,"config","user.name","t")
    os.makedirs(R+"/src"); os.makedirs(R+"/.parallax/demo/reviews")
    open(R+"/src/a.ts","w").write("code\n")
    open(R+"/.parallax/codex.toml","w").write(open(TOML).read())               # committed STRICT policy
    open(R+"/.parallax/demo/spec.md","w").write("spec: tax HALF_UP\n")          # frozen normative contract
    open(R+"/.parallax/demo/slices.md","w").write("S1, S2\n")
    open(R+"/.parallax/demo/validation.md","w").write("full: npm test (strict)\n")
    json.dump({"slug":"demo","slices":list(slices_lock)}, open(R+"/.parallax/demo/slices.lock","w"))
    # v0.38 5.2 — the budget authority is the freeze-time-frozen snapshot, committed with the contract
    sh("python3", os.path.join(PLUGIN,"scripts/pre-freeze-budget.py"), "pin-policy",
       "--policy", R+"/.parallax/codex.toml", "--slug","demo",
       "--out", R+"/.parallax/demo/review-policy.frozen.json")
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","frozen contract + code")
    vt=sh("bash",TH,"HEAD",R).stdout.strip()
    ch=sh("bash",CH,"HEAD","demo",R).stdout.strip()
    rs_slices = rs_slices if rs_slices is not None else [(s,"integrated") for s in slices_lock]
    led = ledgers if ledgers is not None else {s:{} for s,_ in rs_slices}
    import hashlib
    for sid,ov in led.items():
        if ov is None: continue                                                # None => ledger NOT created
        d={"slug":"demo","slice_id":sid,"rounds_used":1,"policy_hash":PHASH,"contract_hash":ch,"findings":[]}; d.update(ov)
        # v0.38 5.3 — every consumed round needs a COMMITTED raw receipt (unless the case overrides)
        if "round_receipts" not in d:
            receipts=[]
            for r in range(1, int(d.get("rounds_used",0))+1):
                raw=json.dumps({"verdict":"pass","findings":[]}).encode()
                name=f"{sid}.round{r}.raw.json"
                open(f"{R}/.parallax/demo/reviews/{name}","wb").write(raw)
                receipts.append({"round":r,"raw_artifact":name,"raw_sha256":hashlib.sha256(raw).hexdigest()})
            d["round_receipts"]=receipts
        json.dump(d, open(f"{R}/.parallax/demo/reviews/{sid}.json","w"))
    rs={"run_id":"r","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":status,"verified_tree":vt,
        "slices":[{"id":s,"status":st} for s,st in rs_slices],"integrated":[s for s,_ in rs_slices],"updated_at":"t"}
    if status=="complete": rs["completion"]={"completed_at":"2026-06-27T00:00:00+00:00","run_id":"r","verified_tree":vt,"run_evidence_sha256":"0"*64,"events_jsonl_sha256":"0"*64,"terminal_event":"run_completed"}
    if status=="running": rs["lock"]={"holder":"r","acquired_at":"t","expires_at":"t2"}
    json.dump(rs, open(R+"/.parallax/demo/run-state.json","w"))
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","complete")
    if mutate: mutate(R)
    return R
def gate(R,slug="demo"): return sh("python3",GATE,"--feature-ref","HEAD","--slug",slug,"--repo",R).returncode
def chg_code(R): open(R+"/src/a.ts","w").write("CHANGED\n"); sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","sneaky code")
def swap_policy(R): open(R+"/.parallax/codex.toml","w").write(PERM); sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","swap policy permissive")
def mutate_contract(R):
    open(R+"/.parallax/demo/spec.md","w").write("spec: rounding unspecified\n")          # weaken the spec...
    open(R+"/.parallax/demo/validation.md","w").write("full: true  # tests disabled\n")   # ...and the gate commands
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","rewrite spec+validation after review")
def bad_internal_slug(R):
    p=R+"/.parallax/demo/run-state.json"; d=json.load(open(p)); d["slug"]="evil"; json.dump(d,open(p,"w"))
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","tamper slug")

cases={
 "happy"                 : (gate(build()), 0),
 "code-changed-after"    : (gate(build(mutate=chg_code)), 1),                                  # verified_tree mismatch
 "contract-mutated-after": (gate(build(mutate=mutate_contract)), 1),                           # v0.26 P0 — contract_hash mismatch
 "missing-ledger"        : (gate(build(ledgers={"S1":{},"S2":None})), 1),
 "parked-slice"          : (gate(build(rs_slices=[("S1","integrated"),("S2","parked")])), 1),
 "identity-mismatch"     : (gate(build(ledgers={"S1":{},"S2":{"slice_id":"S1"}})), 1),
 "ledger-slug-mismatch"  : (gate(build(ledgers={"S1":{},"S2":{"slug":"other"}})), 1),          # P1#4
 "rounds_used=0"         : (gate(build(ledgers={"S1":{"rounds_used":0},"S2":{}})), 1),
 "status!=complete"      : (gate(build(status="running")), 1),
 "sliceset-drop"         : (gate(build(slices_lock=("S1","S2"), rs_slices=[("S1","integrated")], ledgers={"S1":{}})), 1),  # P0#2
 "committed-perm-policy" : (gate(build(mutate=swap_policy)), 1),                               # policy_hash mismatch
 "internal-slug-tamper"  : (gate(build(mutate=bad_internal_slug)), 1),                         # run_state.slug != --slug
}
bad={k:cases[k][0] for k,(got,want) in cases.items() if got!=want}
print("t_epic_gate OK" if not bad else "FAIL "+json.dumps(bad))
sys.exit(0 if not bad else 1)
PY
