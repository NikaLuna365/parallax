#!/usr/bin/env bash
# v0.37.5 5.3 / TRIAGE gates A4(+A5-receipt-side) — EXECUTES the post-green receipt-integrity
# chain, replaying the RUN1 live failure: the S2 "pass" was hand-authored by the orchestrator
# from a malformed GLM JSON envelope, and no post-green round persisted a raw response. Locks:
#   A4a. merge-ledger REFUSES a round with no --raw-response (exit 2, names the receipt rule);
#   A4b. a malformed round (schema-invalid — e.g. bare {"verdict":"ok"}) is a PROVIDER ERROR,
#        never merged; a non-JSON round likewise;
#   A4c. the RUN1 shape: a hand-typed schema-valid "pass" whose --raw-response is the actual
#        MALFORMED envelope -> refused (raw != round: the receipt must BE the verbatim verdict);
#   A4d. a valid round + verbatim raw -> merged; the raw is PERSISTED at the canonical
#        <slice>.round<N>.raw.json and the ledger carries {round, raw_artifact, raw_sha256};
#   A4e. triage refuses a ledger whose receipts don't cover rounds_used (fail closed);
#   A4f. epic-gate re-derives the receipts from the COMMITTED ref: missing raw file, tampered
#        raw bytes (sha mismatch), and schema-invalid raw each HOLD;
#   A4g. merge-ledger refuses to overwrite a DIFFERENT raw under an existing canonical name.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
python3 -c "import jsonschema" 2>/dev/null || { echo "t_postgreen_receipts SKIP (jsonschema not installed — every layer fails closed without it)"; exit 2; }

python3 - "$PLUGIN" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile
PLUGIN = sys.argv[1]
sys.path.insert(0, os.path.join(PLUGIN, "scripts")); import triage as T
ML = os.path.join(PLUGIN, "scripts/merge-ledger.py")
TRI = os.path.join(PLUGIN, "scripts/triage.py")
GATE = os.path.join(PLUGIN, "scripts/epic-gate.py")
PIN = os.path.join(PLUGIN, "scripts/pre-freeze-budget.py")
TH = os.path.join(PLUGIN, "scripts/code-tree-hash.sh"); CH = os.path.join(PLUGIN, "scripts/contract-hash.sh")
TOML = os.path.join(PLUGIN, "assets/codex/codex.toml.example")
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k)
def fail(m): print("FAIL:", m); sys.exit(1)
D = tempfile.mkdtemp(); LED = os.path.join(D, "S1.json")
GOOD = {"verdict": "concerns", "findings": [{"severity": "high", "kind": "safety", "spec_ref": "s#a",
        "where": "src/x.ts:1", "claim": "c", "evidence": "e"}]}
def w(p, doc): json.dump(doc, open(p, "w")); return p
rnd = w(os.path.join(D, "round.json"), GOOD)

# --- A4a) no --raw-response -> refused
p = sh("python3", ML, LED, rnd, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo")
if p.returncode != 2 or "raw response required" not in p.stdout: fail(f"A4a: rc={p.returncode} {p.stdout}")
if os.path.exists(LED): fail("A4a: refused merge still wrote a ledger")

# --- A4b) malformed round: schema-invalid and non-JSON are PROVIDER ERRORS
bad = w(os.path.join(D, "bad.json"), {"verdict": "ok"})
p = sh("python3", ML, LED, bad, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo", "--raw-response", bad)
if p.returncode != 2 or "provider-error" not in p.stdout: fail(f"A4b-schema: rc={p.returncode} {p.stdout}")
nj = os.path.join(D, "envelope.txt"); open(nj, "w").write("GLM says: {verdict: pass maybe...")
p = sh("python3", ML, LED, nj, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo", "--raw-response", nj)
if p.returncode != 2 or "provider-error" not in p.stdout: fail(f"A4b-json: rc={p.returncode} {p.stdout}")

# --- A4c) the RUN1 shape: hand-typed schema-valid pass, raw = the malformed envelope -> refused
handpass = w(os.path.join(D, "hand.json"), {"verdict": "pass", "findings": []})
p = sh("python3", ML, LED, handpass, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo", "--raw-response", nj)
if p.returncode != 2: fail(f"A4c: hand-authored pass over a malformed envelope was merged (rc={p.returncode}) {p.stdout}")

# --- A4d) valid round + verbatim raw -> merged, raw persisted canonically, receipt recorded
raw = w(os.path.join(D, "raw.json"), GOOD)
p = sh("python3", ML, LED, rnd, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo", "--raw-response", raw)
if p.returncode != 0: fail(f"A4d: valid merge failed {p.stdout}{p.stderr}")
canon = os.path.join(D, "S1.round1.raw.json")
if not os.path.exists(canon): fail("A4d: canonical raw not persisted")
led = json.load(open(LED))
rec = led.get("round_receipts", [])
if len(rec) != 1 or rec[0]["round"] != 1 or rec[0]["raw_artifact"] != "S1.round1.raw.json": fail(f"A4d: bad receipt {rec}")
if rec[0]["raw_sha256"] != hashlib.sha256(open(canon, "rb").read()).hexdigest(): fail("A4d: receipt sha mismatch")

# --- A4g) a DIFFERENT raw under the same canonical name is refused (append-only history)
led2dir = tempfile.mkdtemp(); led2 = os.path.join(led2dir, "S1.json")
open(os.path.join(led2dir, "S1.round1.raw.json"), "w").write(json.dumps({"verdict": "pass", "findings": []}))
p = sh("python3", ML, led2, rnd, "--slice", "S1", "--current-diff", "a"*40, "--slug", "demo", "--raw-response", raw)
if p.returncode != 2 or "refusing to overwrite" not in p.stdout: fail(f"A4g: rc={p.returncode} {p.stdout}")

# --- A4e) triage refuses receipts that don't cover rounds_used
led = json.load(open(LED)); led["rounds_used"] = 2   # one receipt, two rounds claimed
w(LED, led)
p = sh("python3", TRI, LED, "--policy", TOML, "--current-diff", "a"*40,
       "--schema", os.path.join(PLUGIN, "assets/codex/review-ledger.schema.json"))
if p.returncode != 2 or "round-receipts-incomplete" not in p.stdout: fail(f"A4e: rc={p.returncode} {p.stdout}")

# --- A4f) epic-gate re-derives from the COMMITTED ref: build a passing repo, then ablate
def build():
    R = tempfile.mkdtemp(); sh("git", "init", "-q", R)
    sh("git", "-C", R, "config", "user.email", "t@t"); sh("git", "-C", R, "config", "user.name", "t")
    os.makedirs(R + "/src"); os.makedirs(R + "/.parallax/demo/reviews")
    open(R + "/src/a.ts", "w").write("code\n")
    open(R + "/.parallax/codex.toml", "w").write(open(TOML).read())
    open(R + "/.parallax/demo/spec.md", "w").write("spec\n"); open(R + "/.parallax/demo/slices.md", "w").write("S1\n")
    open(R + "/.parallax/demo/validation.md", "w").write("full: t\n")
    w(R + "/.parallax/demo/slices.lock", {"slug": "demo", "slices": ["S1"]})
    sh("python3", PIN, "pin-policy", "--policy", R + "/.parallax/codex.toml", "--slug", "demo",
       "--out", R + "/.parallax/demo/review-policy.frozen.json")
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "frozen")
    vt = sh("bash", TH, "HEAD", R).stdout.strip(); ch = sh("bash", CH, "HEAD", "demo", R).stdout.strip()
    rawb = json.dumps({"verdict": "pass", "findings": []}).encode()
    open(R + "/.parallax/demo/reviews/S1.round1.raw.json", "wb").write(rawb)
    w(R + "/.parallax/demo/reviews/S1.json",
      {"slug": "demo", "slice_id": "S1", "rounds_used": 1, "policy_hash": T.policy_hash(T.load_policy(TOML)[0]),
       "contract_hash": ch, "round_receipts": [{"round": 1, "raw_artifact": "S1.round1.raw.json",
                                                "raw_sha256": hashlib.sha256(rawb).hexdigest()}], "findings": []})
    rs = {"run_id": "r", "slug": "demo", "epic": "e", "base_tip": "d"*40, "status": "complete", "verified_tree": vt,
          "slices": [{"id": "S1", "status": "integrated"}], "integrated": ["S1"], "updated_at": "t",
          "completion": {"completed_at": "2026-07-09T00:00:00+00:00", "run_id": "r", "verified_tree": vt,
                         "run_evidence_sha256": "0"*64, "events_jsonl_sha256": "0"*64, "terminal_event": "run_completed"}}
    w(R + "/.parallax/demo/run-state.json", rs)
    sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "complete")
    return R
def gate(R): return sh("python3", GATE, "--feature-ref", "HEAD", "--slug", "demo", "--repo", R)
def commit(R): sh("git", "-C", R, "add", "-A"); sh("git", "-C", R, "commit", "-q", "-m", "x")

R = build()
if gate(R).returncode != 0: fail(f"A4f-happy: {gate(R).stdout}")
R1 = build(); sh("git", "-C", R1, "rm", "-q", ".parallax/demo/reviews/S1.round1.raw.json"); commit(R1)
g = gate(R1)
if g.returncode != 1 or "no committed" not in g.stdout: fail(f"A4f-missing: rc={g.returncode} {g.stdout}")
R2 = build(); open(R2 + "/.parallax/demo/reviews/S1.round1.raw.json", "w").write(json.dumps({"verdict": "pass", "findings": [], "x": 1})); commit(R2)
g = gate(R2)
if g.returncode != 1 or "sha256" not in g.stdout: fail(f"A4f-tamper: rc={g.returncode} {g.stdout}")
R3 = build()
badraw = json.dumps({"verdict": "totally-fine"}).encode()
open(R3 + "/.parallax/demo/reviews/S1.round1.raw.json", "wb").write(badraw)
led3 = json.load(open(R3 + "/.parallax/demo/reviews/S1.json"))
led3["round_receipts"][0]["raw_sha256"] = hashlib.sha256(badraw).hexdigest()   # sha "fixed" — schema still catches it
w(R3 + "/.parallax/demo/reviews/S1.json", led3); commit(R3)
g = gate(R3)
if g.returncode != 1 or "schema-invalid" not in g.stdout: fail(f"A4f-invalid: rc={g.returncode} {g.stdout}")

print("t_postgreen_receipts OK")
PY
