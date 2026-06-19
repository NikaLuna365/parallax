#!/usr/bin/env python3
"""Parallax epic-advance gate — a FEATURE-LEVEL receipt bound to the actual promoted commit.

The gate decides whether `feature/<slug>` may auto-advance the append-only epic. It reads EVERYTHING
from the committed feature ref (never the working tree) and ties the decision to that exact commit, so
none of these slip through (v0.23 audit): an uncommitted/working-tree ledger, code changed after review,
an operator-narrowed slice list, a receipt whose identity doesn't match, or a "verified" with zero
verifier rounds.

For ref R = --feature-ref, the feature is VERIFIED iff ALL hold:
  1. run-state `git show R:.parallax/<slug>/run-state.json` exists, validates (fail-closed), status=="complete".
  2. run-state.verified_tree == code-tree-hash(R)  — the recomputed hash of every tracked non-.parallax/
     file at R. Binds the verdict to the ACTUAL committed tree: a code/test/config change after the run
     completed (which leaves the per-slice ledgers untouched) moves this hash => HOLD.
  3. run-state.slices is non-empty and EVERY slice has status=="integrated" (no parked/pending/
     green-unverified). The slice set comes from the COMMITTED run-state, not a free CLI arg.
  4. each slice's ledger `git show R:.parallax/<slug>/reviews/<id>.json` exists, validates (fail-closed),
     has slice_id == that id (identity), rounds_used >= 1 (a verifier actually ran), and triages GREEN
     against the diff its own fix-proofs were verified at.

Reads policy ONLY from the trusted .parallax/codex.toml; validates run-state + every ledger fail-closed
(no jsonschema / invalid => HOLD). Exit: 0 verified (advance), 1 hold (do NOT advance), 3 bad input.

Usage:
    epic-gate.py --feature-ref <ref> --slug <slug> --policy .parallax/codex.toml [--repo <dir>]
"""
import argparse, json, os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import triage as T

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCHEMA_LEDGER   = os.path.join(_HERE, "..", "assets", "codex", "review-ledger.schema.json")
_SCHEMA_RUNSTATE = os.path.join(_HERE, "..", "assets", "run-state.schema.json")
_TREE_HASH_SH    = os.path.join(_HERE, "code-tree-hash.sh")


def _git_show(repo, ref, path):
    """Contents of <path> AS COMMITTED at <ref>, or None if absent. Never touches the working tree."""
    p = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def _code_tree_hash(repo, ref):
    p = subprocess.run(["bash", _TREE_HASH_SH, ref, repo], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _validate(doc, schema_path):
    """Fail-closed: returns an error string (=> hold) or None if valid."""
    try:
        import jsonschema
    except ImportError:
        return "validator-unavailable: jsonschema not importable (fail-closed)"
    if not os.path.exists(schema_path):
        return f"schema-missing: {schema_path!r}"
    try:
        jsonschema.validate(doc, json.load(open(schema_path)))
        return None
    except Exception as e:
        return f"schema-invalid: {getattr(e, 'message', e)}"


def _verified_diff(ledger):
    """The diff a slice's fixes were proven against (single shared last_verified_diff of its `fixed`
    findings); inconsistent => None; no fixed findings => a sentinel (nothing to settle)."""
    diffs = {f.get("last_verified_diff") for f in ledger.get("findings", []) if f.get("status") == "fixed"}
    diffs.discard(None)
    if len(diffs) > 1:
        return None, "inconsistent-fix-diffs"
    return (next(iter(diffs)) if diffs else "no-fixed-findings"), None


def gate(repo, ref, slug, policy):
    rs_path = f".parallax/{slug}/run-state.json"
    raw = _git_show(repo, ref, rs_path)
    if raw is None:
        return False, {"run_state": f"no committed {rs_path} at {ref}"}
    try:
        rs = json.loads(raw)
    except Exception as e:
        return False, {"run_state": f"bad json: {e}"}
    err = _validate(rs, _SCHEMA_RUNSTATE)
    if err:
        return False, {"run_state": err}
    if rs.get("status") != "complete":
        return False, {"run_state": f"status={rs.get('status')!r} (require 'complete')"}

    # (2) bind to the actual committed tree
    want = rs.get("verified_tree")
    got = _code_tree_hash(repo, ref)
    if not want or not got or want != got:
        return False, {"verified_tree": f"receipt {want!r} != recomputed {got!r} (code changed after review, or missing)"}

    # (3) slice set from the COMMITTED run-state; every slice must be integrated
    slices = rs.get("slices", [])
    if not slices:
        return False, {"slices": "run-state lists no slices"}
    results = {}
    verified = True
    for s in slices:
        sid = s.get("id")
        if s.get("status") != "integrated":
            results[sid] = f"slice status={s.get('status')!r} (not integrated)"; verified = False; continue
        # (4) the slice's COMMITTED ledger
        led_path = f".parallax/{slug}/reviews/{sid}.json"
        lraw = _git_show(repo, ref, led_path)
        if lraw is None:
            results[sid] = f"no committed {led_path}"; verified = False; continue
        try:
            ledger = json.loads(lraw)
        except Exception as e:
            results[sid] = f"bad ledger json: {e}"; verified = False; continue
        lerr = _validate(ledger, _SCHEMA_LEDGER)
        if lerr:
            results[sid] = lerr; verified = False; continue
        if ledger.get("slice_id") != sid:
            results[sid] = f"identity mismatch: ledger slice_id={ledger.get('slice_id')!r} != {sid!r}"; verified = False; continue
        if int(ledger.get("rounds_used", 0)) < 1:
            results[sid] = "rounds_used<1 (no verifier round ran)"; verified = False; continue
        if int(ledger.get("rounds_used", 0)) > policy["max_rounds"]:
            results[sid] = "rounds-exceeded"; verified = False; continue
        diff, derr = _verified_diff(ledger)
        if derr:
            results[sid] = derr; verified = False; continue
        out = T.triage(ledger, policy, diff)
        if out["decision"] != "green":
            results[sid] = f"triage={out['decision']} blockers={out['blockers']} contests={out['contests']}"; verified = False; continue
        results[sid] = "green"
    return verified, results


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--feature-ref", required=True, help="the feature branch/commit being promoted")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--policy", help="path to the TRUSTED .parallax/codex.toml")
    ap.add_argument("--repo", default=".")
    a = ap.parse_args(argv)
    policy, _note = T.load_policy(a.policy)
    okq, results = gate(a.repo, a.feature_ref, a.slug, policy)
    print(json.dumps({"verdict": "verified" if okq else "hold", "feature_ref": a.feature_ref, "detail": results}))
    return 0 if okq else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
