#!/usr/bin/env bash
# v0.37 P0.2 + v0.37.1 freshness — EXECUTES scripts/finalize-gate.py. Builds an epic-gate-PASSING
# committed feature with a v0.37.1 terminal completion receipt bound to the committed evidence:
#   * run-state.completion {completed_at ISO, run_id, verified_tree, run_evidence_sha256,
#     events_jsonl_sha256, terminal_event=run_completed};
#   * a full run-evidence.json (status=complete, matching run_id/slug);
#   * an events.jsonl carrying a same-run run_completed event;
#   * per-slice green arbiter receipts; verifier ledgers; verified_tree.
# The complete, self-consistent bundle finalizes (0). Each freshness ablation holds (1):
# no completion, non-ISO timestamp, evidence run_id mismatch, missing terminal event, evidence
# tamper (committed bytes != recorded sha256), tree mismatch, plus prior missing-arbiter /
# missing-evidence / green-unverified.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }
python3 - "$PLUGIN" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile
PLUGIN=sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN,"scripts")); import triage as T
TOML=os.path.join(PLUGIN,"assets/codex/codex.toml.example")
FG=os.path.join(PLUGIN,"scripts/finalize-gate.py")
TH=os.path.join(PLUGIN,"scripts/code-tree-hash.sh"); CH=os.path.join(PLUGIN,"scripts/contract-hash.sh")
PHASH=T.policy_hash(T.load_policy(TOML)[0])
ISO="2026-06-27T00:00:00+00:00"; VD={"S1":"aaaaaaa","S2":"bbbbbbb"}
def sh(*a): return subprocess.run(a,capture_output=True,text=True)
def w(p,obj): open(p,"w").write(json.dumps(obj))
def sha(p): return hashlib.sha256(open(p,"rb").read()).hexdigest()

def runev(run_id="r", status="complete"):
    return {"schema_version":"parallax-run-evidence-v1","plugin":{"name":"parallax","version":"0.37.1"},
      "run":{"run_id":run_id,"slug":"demo","command_entry":"run","started_at":ISO,"updated_at":ISO,"status":status},
      "repo":{"root":"/x","branch":None,"base_tip":None,"feature_tip":None,"dirty_at_start":False,"dirty_at_end":False},
      "artifacts":{"spec":".parallax/demo/spec.md","slices":None,"validation":None,"slices_lock":None,"run_state":None},
      "capabilities_exercised":{"existing_affordance_review":True,"architecture_fitness":True,"project_scout":False,"intake_handoff":False,"safe_resolution":False},
      "evidence_limits":["not a benchmark result"]}
def evt(et="run_completed", run_id="r"):
    return {"schema_version":"parallax-run-evidence-event-v1","run_id":run_id,"slug":"demo","at":ISO,
            "event_type":et,"actor":"main","summary":"x","artifact_paths":{}}

def build(completion=True, arbiter=True, evidence=True, gu=False,
          bad_ts=False, ev_runid="r", terminal=True, tamper=False, tree_bad=False):
    R=tempfile.mkdtemp(); sh("git","init","-q",R)
    sh("git","-C",R,"config","user.email","t@t"); sh("git","-C",R,"config","user.name","t")
    os.makedirs(R+"/src"); os.makedirs(R+"/.parallax/demo/reviews")
    os.makedirs(R+"/.parallax/demo/arbiter"); os.makedirs(R+"/.parallax/demo/evidence")
    open(R+"/src/a.ts","w").write("code\n")
    open(R+"/.parallax/codex.toml","w").write(open(TOML).read())
    open(R+"/.parallax/demo/spec.md","w").write("spec: tax HALF_UP\n")
    open(R+"/.parallax/demo/slices.md","w").write("S1, S2\n")
    open(R+"/.parallax/demo/validation.md","w").write("full: npm test\n")
    w(R+"/.parallax/demo/slices.lock", {"slug":"demo","slices":["S1","S2"]})
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","frozen")
    vt=sh("bash",TH,"HEAD",R).stdout.strip(); ch=sh("bash",CH,"HEAD","demo",R).stdout.strip()
    for sid in ("S1","S2"):
        w(f"{R}/.parallax/demo/reviews/{sid}.json",
          {"slug":"demo","slice_id":sid,"rounds_used":1,"policy_hash":PHASH,"contract_hash":ch,"findings":[]})
        if arbiter:
            w(f"{R}/.parallax/demo/arbiter/{sid}.json",
              {"schema_version":"parallax-arbiter-receipt-v1","slug":"demo","slice_id":sid,
               "arbiter":"arbiter-1","verdict":"green","verified_diff":VD[sid]})
    rev_p=R+"/.parallax/demo/evidence/run-evidence.json"; evt_p=R+"/.parallax/demo/evidence/events.jsonl"
    if evidence:
        w(rev_p, runev(run_id=ev_runid))
        open(evt_p,"w").write(json.dumps(evt("slice_dispatched"))+"\n"
                              + (json.dumps(evt("run_completed"))+"\n" if terminal else ""))
    rev_sha = sha(rev_p) if evidence else "0"*64        # hashes of the committed-intended evidence bytes
    evt_sha = sha(evt_p) if evidence else "0"*64
    comp_vt = ("f"*40) if tree_bad else vt
    s1={"id":"S1","status":"green-unverified" if gu else "integrated","verified_diff":VD["S1"]}
    if gu: s1.update({"arbiter_verdict":"green","wave_base":"a"*40})
    rs={"run_id":"r","slug":"demo","epic":"feature/epic","base_tip":"d"*40,"status":"complete",
        "verified_tree":comp_vt,"slices":[s1,{"id":"S2","status":"integrated","verified_diff":VD["S2"]}],
        "integrated":["S1","S2"],"updated_at":("t" if bad_ts else ISO)}
    if completion:
        rs["completion"]={"completed_at":("t" if bad_ts else ISO),"run_id":"r","verified_tree":comp_vt,
            "run_evidence_sha256":rev_sha,"events_jsonl_sha256":evt_sha,"terminal_event":"run_completed"}
    w(R+"/.parallax/demo/run-state.json", rs)
    if tamper and evidence:                              # mutate committed bytes AFTER recording the sha
        open(evt_p,"a").write(json.dumps(evt("arbiter_green"))+"\n")
    sh("git","-C",R,"add","-A"); sh("git","-C",R,"commit","-q","-m","complete")
    return R
def fg(R): return sh("python3",FG,"--feature-ref","HEAD","--slug","demo","--repo",R).returncode

cases={
 "happy":              (fg(build()), 0),
 "no-completion":      (fg(build(completion=False)), 1),   # old weak path: updated_at present, no completion
 "bad-timestamp":      (fg(build(bad_ts=True)), 1),
 "evidence-runid":     (fg(build(ev_runid="other")), 1),
 "missing-terminal":   (fg(build(terminal=False)), 1),
 "evidence-tamper":    (fg(build(tamper=True)), 1),
 "tree-mismatch":      (fg(build(tree_bad=True)), 1),
 "no-arbiter":         (fg(build(arbiter=False)), 1),
 "no-evidence":        (fg(build(evidence=False)), 1),
 "green-unverified":   (fg(build(gu=True)), 1),
}
bad={k:v[0] for k,v in cases.items() if v[0]!=v[1]}
print("t_finalize_gate OK" if not bad else "FAIL "+json.dumps(bad))
sys.exit(0 if not bad else 1)
PY
