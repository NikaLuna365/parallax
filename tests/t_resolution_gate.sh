#!/usr/bin/env bash
# v0.31 P1 — EXECUTES scripts/resolution.py (the single writer of queue/receipts/feature-state) and the
# feature-state checks added to scripts/epic-gate.py. Proves: schema-valid queue items only; one-time
# confirmation token; generation strictly +1; the fail-closed set (stale hash, reused token, empty diff,
# unclosed item, unsupported kind); and that the epic gate holds a stale-generation or non-complete feature.
# Exit: 0 all behaved, 2 SKIP (no jsonschema — the writer fails closed without it), 1 a case wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }

python3 - "$PLUGIN" <<'PY'
import json, os, subprocess, sys, tempfile
PLUGIN = sys.argv[1]
RES = os.path.join(PLUGIN, "scripts/resolution.py")
H64 = lambda c: c * 64
OLD, NEW = H64("a"), H64("b"); OID = "c" * 40
def run(*args, **kw):
    return subprocess.run([sys.executable, RES, *args], capture_output=True, text=True, **kw)
def rc(*args): return run(*args).returncode
fails = []
def expect(name, got, want):
    if got != want: fails.append(f"{name}: rc={got} want={want}")

T = tempfile.mkdtemp(); ST = f"{T}/feature-state.json"; Q = f"{T}/resolution-queue.json"; RD = f"{T}/resolutions"
def item(iid, **o):
    d = {"id": iid, "status": "open", "stage": "build", "kind": "spec-gap", "slice_id": "S2",
         "source_contract_hash": OLD, "source_run_id": "RUN1", "spec_refs": ["B/retries"],
         "question": "retries default?", "options": [{"id": "A", "rule": "0", "consequence": "x"},
         {"id": "B", "rule": "3", "consequence": "y"}], "blocked_slices": ["S2"], "source_receipts": ["reviews/S2.json#N1"]}
    d.update(o); p = f"{T}/{iid}.json"; json.dump(d, open(p, "w")); return p

expect("init-feature", rc("init-feature", ST, "--slug", "demo", "--feature-id", "F1", "--run-id", "RUN1",
        "--base-oid", OID, "--tip-oid", OID, "--contract-hash", OLD), 0)
expect("add valid item", rc("add-item", Q, "--slug", "demo", "--item-file", item("R-S2-0001")), 0)
expect("item without spec_refs -> reject", rc("add-item", Q, "--slug", "demo", "--item-file", item("R-S2-0009", spec_refs=[])), 2)
def item_drop(iid, key):
    p = item(iid); d = json.load(open(p)); d.pop(key, None); json.dump(d, open(p, "w")); return p
expect("item without source hash -> reject", rc("add-item", Q, "--slug", "demo", "--item-file", item_drop("R-S2-0008", "source_contract_hash")), 2)
# unsupported kind (e.g. safety) is not a resolution item:
bad_kind = item("R-S2-0007"); d = json.load(open(bad_kind)); d["kind"] = "safety"; json.dump(d, open(bad_kind, "w"))
expect("unsupported kind -> reject", rc("add-item", Q, "--slug", "demo", "--item-file", bad_kind), 2)
# duplicate id -> append-only identity
expect("duplicate id -> reject", rc("add-item", Q, "--slug", "demo", "--item-file", item("R-S2-0001")), 2)

run("transition", ST, "--slug", "demo", "--to", "needs-resolution")
run("transition", ST, "--slug", "demo", "--to", "resolving")
tok = json.loads(run("mint-token", "--slug", "demo", "--from-gen", "1", "--batch-id", "RB-0001",
                     "--old-hash", OLD, "--new-hash", NEW).stdout)["token"]
dec = f"{T}/dec.json"; json.dump([{"item_id": "R-S2-0001", "decision": "choose-option", "option_id": "B", "rule": "3"}], open(dec, "w"))
def apply(state=ST, batch="RB-0001", srun="RUN1", nrun="RUN2", old=OLD, new=NEW, token=tok, decs=dec):
    return rc("apply", state, "--queue", Q, "--resolutions-dir", RD, "--slug", "demo", "--batch-id", batch,
              "--source-run-id", srun, "--new-run-id", nrun, "--old-hash", old, "--new-hash", new,
              "--token", token, "--human-text", "use 3", "--decisions", decs)
# wrong token / stale hash / empty diff fail BEFORE state changes:
expect("wrong token -> escalate", apply(token="PARALLAX-RESOLVE:demo:g1->g2:RB-0001:aaaaaaaaaaaa:badbadbadbad"), 2)
expect("stale source hash -> escalate", apply(old=H64("f")), 2)
empty_tok = json.loads(run("mint-token", "--slug", "demo", "--from-gen", "1", "--batch-id", "RB-0001",
                           "--old-hash", OLD, "--new-hash", OLD).stdout)["token"]
expect("empty contract diff -> escalate", apply(new=OLD, token=empty_tok), 2)
# unclosed blocking item (decisions miss R-S2-0001):
empty_dec = f"{T}/empty.json"; json.dump([{"item_id": "R-NOPE-0001", "decision": "choose-option"}], open(empty_dec, "w"))
expect("unclosed blocking item -> escalate", apply(decs=empty_dec), 2)
# happy apply -> generation strictly +1, receipt valid
expect("apply happy", apply(), 0)
st = json.load(open(ST))
if st["generation"] != 2 or st["status"] != "running" or st["parent_run_id"] != "RUN1" or st["resolution_chain"] != ["RB-0001"]:
    fails.append(f"feature-state after apply wrong: {st}")
r = json.load(open(f"{RD}/RB-0001.json"))
if r["to_generation"] != r["from_generation"] + 1 or r["invalidation_scope"] != "all-slices":
    fails.append("receipt generation/invalidation wrong")
# reused token / already-applied batch:
run("transition", ST, "--slug", "demo", "--to", "needs-resolution"); run("transition", ST, "--slug", "demo", "--to", "resolving")
tok2 = json.loads(run("mint-token", "--slug", "demo", "--from-gen", "2", "--batch-id", "RB-0001",
                      "--old-hash", NEW, "--new-hash", OLD).stdout)["token"]
expect("reused batch id -> escalate", apply(batch="RB-0001", srun="RUN2", nrun="RUN3", old=NEW, new=OLD, token=tok2), 2)

print("SECTION-A-OK" if not fails else "SECTION-A-FAIL " + json.dumps(fails))
sys.exit(0 if not fails else 1)
PY
A=$?

# ---- Section B: epic-gate feature-state consistency ----
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PLUGIN" <<'PY'
import json, os, subprocess, sys, tempfile
PLUGIN = sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN, "scripts")); import triage as T
TOML = os.path.join(PLUGIN, "assets/codex/codex.toml.example")
GATE = os.path.join(PLUGIN, "scripts/epic-gate.py")
TH = os.path.join(PLUGIN, "scripts/code-tree-hash.sh"); CH = os.path.join(PLUGIN, "scripts/contract-hash.sh")
PH = T.policy_hash(T.load_policy(TOML)[0])
def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def build(fs_status="complete", rs_gen=1, fs_gen=1, run_id="RUN1", active_run="RUN1"):
    R = tempfile.mkdtemp(); sh("git", "init", "-q", R)
    sh("git", "-C", R, "config", "user.email", "t@t"); sh("git", "-C", R, "config", "user.name", "t")
    os.makedirs(R + "/src"); os.makedirs(R + "/.parallax/demo/reviews")
    open(R + "/src/a.ts", "w").write("code\n")
    open(R + "/.parallax/codex.toml", "w").write(open(TOML).read())
    open(R + "/.parallax/demo/spec.md", "w").write("spec\n"); open(R + "/.parallax/demo/slices.md", "w").write("S1\n")
    open(R + "/.parallax/demo/validation.md", "w").write("full: t\n")
    json.dump({"slug": "demo", "slices": ["S1"]}, open(R + "/.parallax/demo/slices.lock", "w"))
    # v0.37.5 5.2 — pinned budget authority, committed with the contract
    sh("python3", os.path.join(PLUGIN, "scripts/pre-freeze-budget.py"), "pin-policy",
       "--policy", R + "/.parallax/codex.toml", "--slug", "demo",
       "--out", R + "/.parallax/demo/review-policy.frozen.json")
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "c")
    vt = sh("bash", TH, "HEAD", R).stdout.strip(); ch = sh("bash", CH, "HEAD", "demo", R).stdout.strip()
    import hashlib as _h
    _raw = json.dumps({"verdict": "pass", "findings": []}).encode()             # v0.37.5 5.3 raw receipt
    open(R + "/.parallax/demo/reviews/S1.round1.raw.json", "wb").write(_raw)
    json.dump({"slug": "demo", "slice_id": "S1", "rounds_used": 1, "policy_hash": PH, "contract_hash": ch,
               "round_receipts": [{"round": 1, "raw_artifact": "S1.round1.raw.json",
                                   "raw_sha256": _h.sha256(_raw).hexdigest()}], "findings": []},
              open(R + "/.parallax/demo/reviews/S1.json", "w"))
    rs = {"run_id": run_id, "slug": "demo", "epic": "feature/epic", "base_tip": "d" * 40, "status": "complete",
          "verified_tree": vt, "feature_id": "F1", "contract_generation": rs_gen,
          "slices": [{"id": "S1", "status": "integrated"}], "integrated": ["S1"], "updated_at": "t"}
    rs["completion"] = {"completed_at": "2026-06-27T00:00:00+00:00", "run_id": run_id, "verified_tree": vt, "run_evidence_sha256": "0"*64, "events_jsonl_sha256": "0"*64, "terminal_event": "run_completed"}
    json.dump(rs, open(R + "/.parallax/demo/run-state.json", "w"))
    fs = {"schema_version": 1, "feature_id": "F1", "slug": "demo", "generation": fs_gen, "active_run_id": active_run,
          "parent_run_id": None if fs_gen == 1 else "RUNx", "generation_base_oid": "d" * 40,
          "feature_tip_before_generation": "d" * 40, "contract_hash": ch, "status": fs_status,
          "resolution_chain": [] if fs_gen == 1 else [f"RB-{i:04d}" for i in range(1, fs_gen)]}
    json.dump(fs, open(R + "/.parallax/demo/feature-state.json", "w"))
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "complete")
    return R
def gate(R): return sh(sys.executable, GATE, "--feature-ref", "HEAD", "--slug", "demo", "--repo", R).returncode
cases = {
    "complete+consistent -> verified": (gate(build()), 0),
    "feature status running -> hold": (gate(build(fs_status="running")), 1),
    "stale generation (run gen1, feature gen2) -> hold": (gate(build(rs_gen=1, fs_gen=2)), 1),
    "run_id != active_run_id -> hold": (gate(build(run_id="RUN1", active_run="RUN9")), 1),
}
bad = {k: g for k, (g, w) in cases.items() if g != w}
print("SECTION-B-OK" if not bad else "SECTION-B-FAIL " + json.dumps(bad))
sys.exit(0 if not bad else 1)
PY
B=$?

if [ "$A" = 2 ] || [ "$B" = 2 ]; then echo "SKIP"; exit 2; fi
[ "$A" = 0 ] && [ "$B" = 0 ] && { echo "t_resolution_gate OK"; exit 0; } || { echo "t_resolution_gate FAIL (A=$A B=$B)"; exit 1; }
