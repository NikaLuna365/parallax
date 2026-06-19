#!/usr/bin/env python3
"""Parallax epic-advance gate — computes feature -> epic verification MECHANICALLY from the COMMITTED
per-slice review receipts (ledgers), so the append-only epic is NEVER advanced on a free-floating
`PARALLAX_VERIFIED=1` (v0.22 P1#4: that variable was only read, never computed — a preset or stale 1
silently lifted the hold).

A feature is VERIFIED iff, for EVERY integrated slice:
  * a committed ledger  .parallax/<slug>/reviews/<slice_id>.json  EXISTS — no ledger means the verifier
    never produced a receipt for that slice (e.g. on_missing="warn"): UNVERIFIED => hold; AND
  * that ledger triages GREEN at the diff its own fix-proofs were verified against (so every blocker
    was positively codex-verified against the reviewed tree, none merely stamped); AND
  * rounds_used <= [review].max_rounds.

Like triage.py, the policy is read ONLY from the trusted .parallax/codex.toml and each ledger is
validated against the schema FAIL-CLOSED (no jsonschema / invalid ledger => hold, never advance). The
orchestrator gates the epic push on exit 0 — there is no env override and nothing to preset.

Exit: 0 verified (advance epic), 1 hold (do NOT advance), 3 bad input. Prints a JSON verdict.

Usage:
    epic-gate.py --policy .parallax/codex.toml --reviews-dir .parallax/<slug>/reviews --slices S1,S2,S3
"""
import argparse, json, os, sys

# Reuse triage.py's vetted logic (same policy load, same green/block/escalate, same fail-closed schema).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import triage as T

_DEFAULT_SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "assets", "codex", "review-ledger.schema.json")


def _verified_diff(ledger):
    """The diff a slice's fixes were proven against: the single `last_verified_diff` shared by its
    `fixed` findings. Disagreement => inconsistent receipt (None). No fixed findings => the diff is
    irrelevant (nothing to settle), return a sentinel so triage can still judge open/advisory."""
    diffs = {f.get("last_verified_diff") for f in ledger.get("findings", []) if f.get("status") == "fixed"}
    diffs.discard(None)
    if len(diffs) > 1:
        return None, "inconsistent-fix-diffs"
    return (next(iter(diffs)) if diffs else "no-fixed-findings"), None


def gate_slice(path, policy, schema_path):
    if not os.path.exists(path):
        return False, "no-ledger (verifier produced no receipt for this slice)"
    try:
        ledger = json.load(open(path))
    except Exception as e:
        return False, f"bad-ledger: {e}"
    err = T.validate_ledger(ledger, schema_path, require=True)        # fail-closed
    if err:
        return False, err
    diff, derr = _verified_diff(ledger)
    if derr:
        return False, derr
    out = T.triage(ledger, policy, diff)
    if out["decision"] != "green":
        return False, f"triage={out['decision']} blockers={out['blockers']} contests={out['contests']}"
    if int(ledger.get("rounds_used", 0)) > policy["max_rounds"]:
        return False, "rounds-exceeded"
    return True, "green"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", help="path to the TRUSTED .parallax/codex.toml")
    ap.add_argument("--reviews-dir", required=True)
    ap.add_argument("--slices", required=True,
                    help="comma-separated integrated slice ids — each MUST have a committed ledger")
    ap.add_argument("--schema", default=_DEFAULT_SCHEMA)
    a = ap.parse_args(argv)
    policy, _note = T.load_policy(a.policy)
    slices = [s.strip() for s in a.slices.split(",") if s.strip()]
    if not slices:
        print(json.dumps({"verdict": "hold", "reason": "no integrated slices given"})); return 3
    results, verified = {}, True
    for sid in slices:
        okq, why = gate_slice(os.path.join(a.reviews_dir, f"{sid}.json"), policy, a.schema)
        results[sid] = why
        verified = verified and okq
    print(json.dumps({"verdict": "verified" if verified else "hold", "slices": results}))
    return 0 if verified else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
