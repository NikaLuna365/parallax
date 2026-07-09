#!/usr/bin/env bash
# v0.38 5.2 / TRIAGE gates A3+A5 — EXECUTES the pinned-budget authority end to end, replaying
# the RUN1 live bypass: an epic-gate HOLD on rounds_used=3 > max_rounds=2 was cleared by
# sed-editing codex.toml 2->3 and re-stamping all ledgers. Locks:
#   A3a. rounds_used=3 vs pinned budget 2 -> epic-gate HOLD (reason names the PINNED budget);
#   A3b. the RUN1 replay — edit codex.toml max_rounds 2->3, re-stamp the ledger to the live
#        policy hash, commit -> HOLD STILL STANDS (re-stamped hash is sanctioned by no amendment);
#   A3c. editing codex.toml WITHOUT re-stamping -> HOLD (live/pinned policy_hash mismatch);
#   A3d. a recorded review-budget amendment (BA-1: human-repeated machine-minted token) +
#        codex.toml matching + ledgers re-stamped to the amended hash -> gate VERIFIES;
#   A5a. merge-ledger refuses round pinned_max+1 with no amendment (exit 5, names the
#        amendment path — an assumption_recorded/codex.toml edit is not authority);
#   A5b. the same third round WITH BA-1 recorded -> merges;
#   A5c. a forged amendment (wrong grant token) never sanctions anything (gate + merge refuse);
#   PIN.  pin-policy refuses to overwrite a DIFFERENT snapshot (the pin is immutable).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "t_pinned_budget SKIP (jsonschema not installed — the gates fail closed without it)"; exit 2; }

python3 - "$PLUGIN" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile
PLUGIN = sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN, "scripts"))
import triage as T
import budget_chain as BC
TOML = os.path.join(PLUGIN, "assets/codex/codex.toml.example")
GATE = os.path.join(PLUGIN, "scripts/epic-gate.py")
ML = os.path.join(PLUGIN, "scripts/merge-ledger.py")
CA = os.path.join(PLUGIN, "scripts/contract-amend.py")
PIN = os.path.join(PLUGIN, "scripts/pre-freeze-budget.py")
TH = os.path.join(PLUGIN, "scripts/code-tree-hash.sh"); CH = os.path.join(PLUGIN, "scripts/contract-hash.sh")
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k)
def fail(msg): print("FAIL:", msg); sys.exit(1)

# the two implementations of the policy hash must be LOCKED together
pol = T.load_policy(TOML)[0]
assert T.policy_hash(pol) == BC.policy_hash(pol), "triage.policy_hash != budget_chain.policy_hash"
PIN_HASH = T.policy_hash(pol)                      # pinned (strict example toml, max_rounds=2)
NEW_POLICY = dict(pol, max_rounds=3)
NEW_HASH = BC.policy_hash(NEW_POLICY)

def rawfile(R, sid, rnd):
    raw = json.dumps({"verdict": "pass", "findings": []}).encode()
    name = f"{sid}.round{rnd}.raw.json"
    open(f"{R}/.parallax/demo/reviews/{name}", "wb").write(raw)
    return {"round": rnd, "raw_artifact": name, "raw_sha256": hashlib.sha256(raw).hexdigest()}

def build(rounds_used=3, ledger_hash=None):
    R = tempfile.mkdtemp(); sh("git", "init", "-q", R)
    sh("git", "-C", R, "config", "user.email", "t@t"); sh("git", "-C", R, "config", "user.name", "t")
    os.makedirs(R + "/src"); os.makedirs(R + "/.parallax/demo/reviews")
    open(R + "/src/a.ts", "w").write("code\n")
    open(R + "/.parallax/codex.toml", "w").write(open(TOML).read())
    open(R + "/.parallax/demo/spec.md", "w").write("spec\n"); open(R + "/.parallax/demo/slices.md", "w").write("S1\n")
    open(R + "/.parallax/demo/validation.md", "w").write("full: t\n")
    json.dump({"slug": "demo", "slices": ["S1"]}, open(R + "/.parallax/demo/slices.lock", "w"))
    p = sh("python3", PIN, "pin-policy", "--policy", R + "/.parallax/codex.toml", "--slug", "demo",
           "--out", R + "/.parallax/demo/review-policy.frozen.json")
    assert p.returncode == 0, p.stdout + p.stderr
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "frozen")
    vt = sh("bash", TH, "HEAD", R).stdout.strip(); ch = sh("bash", CH, "HEAD", "demo", R).stdout.strip()
    receipts = [rawfile(R, "S1", r) for r in range(1, rounds_used + 1)]
    json.dump({"slug": "demo", "slice_id": "S1", "rounds_used": rounds_used,
               "policy_hash": ledger_hash or PIN_HASH, "contract_hash": ch,
               "round_receipts": receipts, "findings": []},
              open(R + "/.parallax/demo/reviews/S1.json", "w"))
    rs = {"run_id": "r", "slug": "demo", "epic": "feature/epic", "base_tip": "d" * 40, "status": "complete",
          "verified_tree": vt, "slices": [{"id": "S1", "status": "integrated"}], "integrated": ["S1"],
          "updated_at": "t",
          "completion": {"completed_at": "2026-07-09T00:00:00+00:00", "run_id": "r", "verified_tree": vt,
                         "run_evidence_sha256": "0" * 64, "events_jsonl_sha256": "0" * 64,
                         "terminal_event": "run_completed"}}
    json.dump(rs, open(R + "/.parallax/demo/run-state.json", "w"))
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "complete")
    return R

def gate(R): return sh("python3", GATE, "--feature-ref", "HEAD", "--slug", "demo", "--repo", R)
def commit(R, m): sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", m)
def sed_toml(R):
    import re as _re
    t = open(R + "/.parallax/codex.toml").read()
    t2 = _re.sub(r"(?m)^(max_rounds\s+=\s+)2", r"\g<1>3", t)   # the RUN1 sed: max_rounds 2->3
    assert t2 != t, "sed_toml matched nothing"
    open(R + "/.parallax/codex.toml", "w").write(t2)
def restamp(R, h):
    p = R + "/.parallax/demo/reviews/S1.json"; d = json.load(open(p)); d["policy_hash"] = h; json.dump(d, open(p, "w"))
def record_ba1(R, token=None):
    tok = token or BC.expected_token("demo", "BA-1", PIN_HASH, NEW_HASH)
    return sh("python3", CA, "record-budget", "--repo", R, "--slug", "demo", "--amendment-id", "BA-1",
              "--rationale", "S1 round 3 closed two genuine MEDIA_ROOT-deletion safety bugs",
              "--evidence", "reviews/S1.round3.raw.json", "--prev-policy-hash", PIN_HASH,
              "--new-policy", json.dumps(NEW_POLICY), "--grant-token", tok)

# --- A3a) rounds-exceeded vs the PINNED budget -> HOLD
R = build(rounds_used=3)
g = gate(R)
if g.returncode != 1 or "PINNED budget" not in g.stdout: fail(f"A3a: expected pinned-budget HOLD, got rc={g.returncode}: {g.stdout}")

# --- A3b) the RUN1 replay: sed codex.toml + re-stamp ledger to the live hash + commit -> STILL HOLD
sed_toml(R)
live_hash = None
import tomllib
review = tomllib.loads(open(R + "/.parallax/codex.toml").read()).get("review", {})
live_hash = BC.policy_hash({k: review.get(k, pol[k]) for k in ("max_rounds", "block_severities", "advisory_severities", "always_block_kinds")})
restamp(R, live_hash)
commit(R, "sed max_rounds 2->3 + re-stamp (the RUN1 bypass)")
g = gate(R)
if g.returncode != 1: fail(f"A3b: the sed+re-stamp bypass CLEARED the hold (rc={g.returncode}): {g.stdout}")

# --- A3c) toml edit alone (fresh repo) -> live/pinned mismatch HOLD
R2 = build(rounds_used=1)
sed_toml(R2); commit(R2, "sed only")
g = gate(R2)
if g.returncode != 1 or "not a budget amendment" not in g.stdout: fail(f"A3c: toml-edit-only did not HOLD on mismatch: rc={g.returncode} {g.stdout}")

# --- A3d) the SANCTIONED path: BA-1 recorded (machine-minted token) + toml matches + ledgers re-stamped -> VERIFIES
p = record_ba1(R)
if p.returncode != 0: fail(f"A3d: record-budget failed: {p.stdout}{p.stderr}")
restamp(R, NEW_HASH)
commit(R, "BA-1 + re-stamp to amended hash")
g = gate(R)
if g.returncode != 0: fail(f"A3d: sanctioned amendment did not clear the hold: {g.stdout}")

# --- A5c) a FORGED amendment (wrong token) is refused at record time…
R3 = build(rounds_used=2)
p = record_ba1(R3, token="PARALLAX-BUDGET-GRANT:demo:BA-1:" + "0" * 16 + ":" + "1" * 16)
if p.returncode == 0: fail("A5c: a forged grant token was accepted by record-budget")
# …and a hand-written forged record file never sanctions the gate
os.makedirs(R3 + "/.parallax/demo/amendments", exist_ok=True)
forged = {"schema_version": "parallax-review-budget-amendment-v1", "slug": "demo", "amendment_id": "BA-1",
          "kind": "review-budget-amendment", "rationale": "forged", "evidence": ["x"],
          "prev_policy_hash": PIN_HASH, "new_policy_hash": NEW_HASH, "new_policy": NEW_POLICY,
          "grant_token": "PARALLAX-BUDGET-GRANT:demo:BA-1:forged:forged",
          "approved_by": "human", "approved_at": "2026-07-09T00:00:00Z"}
json.dump(forged, open(R3 + "/.parallax/demo/amendments/BA-1.json", "w"))
sed_toml(R3); restamp(R3, NEW_HASH); commit(R3, "forged BA-1")
g = gate(R3)
if g.returncode != 1: fail(f"A5c: a forged amendment record sanctioned the gate: {g.stdout}")

# --- A5a/A5b) merge-ledger enforces the pinned budget at ingestion
R4 = build(rounds_used=0)
led = R4 + "/.parallax/demo/reviews/S1.json"
os.unlink(led)  # start fresh; merge-ledger will create it
rnd = R4 + "/r.json"; json.dump({"verdict": "pass", "findings": []}, open(rnd, "w"))
pinned = R4 + "/.parallax/demo/review-policy.frozen.json"
def ml():
    return sh("python3", ML, led, rnd, "--slice", "S1", "--current-diff", "a" * 40, "--slug", "demo",
              "--pinned-policy", pinned, "--raw-response", rnd)
r1, r2 = ml(), ml()
if r1.returncode != 0 or r2.returncode != 0: fail(f"A5a: rounds 1-2 within pinned budget failed: {r1.stdout}{r2.stdout}")
r3 = ml()
if r3.returncode != 5 or "round-budget-exhausted" not in r3.stdout: fail(f"A5a: round 3 beyond pinned budget was not refused (rc={r3.returncode}): {r3.stdout}")
p = record_ba1(R4)
if p.returncode != 0: fail(f"A5b: record-budget failed: {p.stdout}{p.stderr}")
r3b = ml()
if r3b.returncode != 0: fail(f"A5b: round 3 with a recorded BA-1 was refused: {r3b.stdout}")
d = json.load(open(led))
if d.get("policy_hash") != NEW_HASH: fail(f"A5b: ledger not stamped with the AMENDED effective hash: {d.get('policy_hash')}")

# --- PIN) the pin is immutable: re-pinning after a toml edit refuses to overwrite
sed_toml(R4)
p = sh("python3", PIN, "pin-policy", "--policy", R4 + "/.parallax/codex.toml", "--slug", "demo", "--out", pinned)
if p.returncode == 0: fail("PIN: pin-policy overwrote a DIFFERENT existing snapshot")

print("t_pinned_budget OK")
PY
