#!/usr/bin/env python3
"""Parallax standalone finalize gate (v0.37 P0.2 + P1.5).

A SINGLE mechanical gate that must pass before a feature push / epic advancement, so
completion never depends only on ideal orchestrator Step-4 behaviour. It reads everything
from the committed feature ref (never the working tree) and fails closed.

Finalize is allowed (exit 0) for ref R + slug S iff ALL hold:
  1. run-state committed at R, valid JSON, status == "complete", slug == S, and
     updated_at non-empty (a missing or stale checkpoint => HOLD — P1.5).
  2. NO slice is "green-unverified": owed cross-model verification must be drained
     before finalize, even when a build legitimately paused there (P0.2.4 / .5).
  3. Required evidence artifacts are committed at R:
     .parallax/<S>/evidence/run-evidence.json AND .../events.jsonl (P1.5.6).
  4. EVERY slice has a committed, schema-valid arbiter receipt
     .parallax/<S>/arbiter/<id>.json with slug+slice_id identity and verdict == "green";
     its verified_diff matches the run-state slice's verified_diff when that is set
     (P0.2.2 / .3 — the orchestrator cannot self-green or fold arbitration inline).
  5. scripts/epic-gate.py returns "verified" for R+S — the existing per-slice cross-model
     verifier ledger / contract-hash / verified-tree / frozen-slice-set checks all pass
     (reused, never duplicated).

The receipt PRESENCE + identity + green verdict is mechanical. That the arbiter was a
genuinely independent dispatch (not the orchestrator wearing the arbiter hat) is a
prompt-contract obligation; the gate enforces the trail, the contract enforces the role.

Exit: 0 finalize-ok, 1 hold (do NOT finalize/push/advance), 3 bad input (treated as hold).
"""
import argparse
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_EPIC_GATE = os.path.join(_HERE, "epic-gate.py")
_SCHEMA_ARBITER = os.path.join(_HERE, "..", "assets", "arbiter-receipt.schema.json")


def _git_show(repo, ref, path):
    p = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def _validate(doc, schema_path):
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


def gate(repo, ref, slug):
    rs_path = f".parallax/{slug}/run-state.json"
    raw = _git_show(repo, ref, rs_path)
    if raw is None:
        return 1, {"run_state": f"no committed {rs_path} at {ref}"}
    try:
        rs = json.loads(raw)
    except Exception as e:
        return 1, {"run_state": f"bad json: {e}"}
    if rs.get("status") != "complete":
        return 1, {"run_state": f"status={rs.get('status')!r} (require 'complete')"}
    if rs.get("slug") != slug:
        return 1, {"run_state": f"slug={rs.get('slug')!r} != {slug!r}"}
    if not rs.get("updated_at"):
        return 1, {"run_state": "updated_at empty/missing (stale checkpoint)"}

    # (2) green-unverified must be drained before finalize
    gu = [s.get("id") for s in rs.get("slices", []) if s.get("status") == "green-unverified"]
    if gu:
        return 1, {"green_unverified": f"slices {gu} owe cross-model verification; cannot finalize"}

    # (3) required evidence artifacts present at the committed ref
    for ev in ("run-evidence.json", "events.jsonl"):
        if _git_show(repo, ref, f".parallax/{slug}/evidence/{ev}") is None:
            return 1, {"evidence": f"missing committed .parallax/{slug}/evidence/{ev}"}

    # (4) per-slice arbiter receipt
    arb = {}
    for s in rs.get("slices", []):
        sid = s.get("id")
        araw = _git_show(repo, ref, f".parallax/{slug}/arbiter/{sid}.json")
        if araw is None:
            arb[sid] = "no committed arbiter receipt"
            continue
        try:
            ar = json.loads(araw)
        except Exception as e:
            arb[sid] = f"bad json: {e}"
            continue
        verr = _validate(ar, _SCHEMA_ARBITER)
        if verr:
            arb[sid] = verr
            continue
        if ar.get("slug") != slug or ar.get("slice_id") != sid:
            arb[sid] = "arbiter receipt identity mismatch"
            continue
        if ar.get("verdict") != "green":
            arb[sid] = f"arbiter verdict={ar.get('verdict')!r} (require 'green')"
            continue
        want = s.get("verified_diff")
        if want and ar.get("verified_diff") != want:
            arb[sid] = f"arbiter verified_diff {ar.get('verified_diff')!r} != run-state {want!r}"
            continue
        arb[sid] = "green"
    bad = {k: v for k, v in arb.items() if v != "green"}
    if bad:
        return 1, {"arbiter_receipts": bad}

    # (5) delegate the deep verifier/contract/tree/slice-set checks to the epic gate
    p = subprocess.run(
        ["python3", _EPIC_GATE, "--feature-ref", ref, "--slug", slug, "--repo", repo],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return 1, {"epic_gate": "hold", "detail": (p.stdout.strip() or p.stderr.strip())}
    return 0, {"verdict": "finalize-ok", "arbiter_receipts": "all-green", "epic_gate": "verified"}


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37 standalone finalize gate.")
    ap.add_argument("--feature-ref", required=True)
    ap.add_argument("--slug", required=True)
    ap.add_argument("--repo", default=".")
    a = ap.parse_args(argv)
    code, detail = gate(a.repo, a.feature_ref, a.slug)
    print(json.dumps({"verdict": "finalize-ok" if code == 0 else "hold",
                      "feature_ref": a.feature_ref, "detail": detail}))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
