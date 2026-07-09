#!/usr/bin/env python3
"""Parallax standalone finalize gate — freshness-bound (v0.37 P0.2 + P1.5; hardened v0.37.1).

A SINGLE mechanical gate that must pass before a feature push / epic advancement, so
completion never depends only on ideal orchestrator Step-4 behaviour. It reads everything
from the committed feature ref (never the working tree) and fails closed.

v0.37.0 treated "fresh run-state" as merely a non-empty `updated_at`. v0.37.1 makes freshness
a real, mechanical binding: the terminal run-state, the terminal evidence files, the terminal
`run_completed` event, and the verified code tree must all agree. Finalize is allowed (exit 0)
for ref R + slug S iff ALL hold (TZ v0.37.1 §4.2):

  1. run-state committed at R and valid JSON.
  2. run-state validates against assets/run-state.schema.json (fail-closed if jsonschema absent).
  3. status == "complete" and slug == S.
  4. `updated_at` and `completion.completed_at` both parse as ISO-8601 (a bare "t" is rejected).
  5. completion.run_id == run_state.run_id.
  6. completion.verified_tree == run_state.verified_tree (and terminal_event == "run_completed").
  7. completion.verified_tree == code-tree-hash(R) — the recomputed tree of the committed ref.
  8. committed run-evidence.json exists and validates against assets/run-evidence.schema.json.
  9. run-evidence.run.run_id == run_state.run_id.
 10. run-evidence.run.slug == S.
 11. run-evidence.run.status == "complete".
 12. committed events.jsonl exists.
 13. every non-empty events.jsonl line validates against assets/run-evidence-event.schema.json.
 14. events.jsonl carries >=1 `run_completed` event with the same run_id and slug.
 15. sha256 of the committed run-evidence.json / events.jsonl bytes == completion.*_sha256.
 16. if run_state.lock is a non-null object, its holder is the same run_id.
 17. v0.37.0 requirements still hold: no `green-unverified` slice; every slice has a committed,
     schema-valid green arbiter receipt; and scripts/epic-gate.py returns "verified" (the deep
     per-slice verifier ledger / contract-hash / verified-tree / frozen-slice-set checks).

The completion receipt binds run-state to the exact terminal evidence bytes WITHOUT a
self-referential dependency on the final commit oid. Exit: 0 finalize-ok, 1 hold, 3 bad input.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime

_HERE = os.path.dirname(os.path.abspath(__file__))
_EPIC_GATE = os.path.join(_HERE, "epic-gate.py")
_CODE_TREE_HASH_SH = os.path.join(_HERE, "code-tree-hash.sh")
_ASSETS = os.path.join(_HERE, "..", "assets")
_SCHEMA_ARBITER = os.path.join(_ASSETS, "arbiter-receipt.schema.json")
_SCHEMA_SWEEP   = os.path.join(_ASSETS, "sweep-receipt.schema.json")
_SCHEMA_RUNSTATE = os.path.join(_ASSETS, "run-state.schema.json")
_SCHEMA_RUNEVIDENCE = os.path.join(_ASSETS, "run-evidence.schema.json")
_SCHEMA_EVENT = os.path.join(_ASSETS, "run-evidence-event.schema.json")


def _git_show_bytes(repo, ref, path):
    """Raw committed bytes of <path> at <ref> (for hashing), or None if absent."""
    p = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], capture_output=True)
    return p.stdout if p.returncode == 0 else None


def _git_show(repo, ref, path):
    b = _git_show_bytes(repo, ref, path)
    return b.decode("utf-8", "replace") if b is not None else None


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


def _is_iso(s):
    if not isinstance(s, str) or not s.strip():
        return False
    v = s.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        datetime.fromisoformat(v)
        return True
    except ValueError:
        return False


def _code_tree_hash(repo, ref):
    p = subprocess.run(["bash", _CODE_TREE_HASH_SH, ref, repo], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def gate(repo, ref, slug):
    # (1) run-state present + valid JSON
    raw = _git_show(repo, ref, f".parallax/{slug}/run-state.json")
    if raw is None:
        return 1, {"run_state": f"no committed .parallax/{slug}/run-state.json at {ref}"}
    try:
        rs = json.loads(raw)
    except Exception as e:
        return 1, {"run_state": f"bad json: {e}"}
    # (2) run-state schema-valid (fail-closed if jsonschema missing)
    serr = _validate(rs, _SCHEMA_RUNSTATE)
    if serr:
        return 1, {"run_state": serr}
    # (3) status + slug
    if rs.get("status") != "complete":
        return 1, {"run_state": f"status={rs.get('status')!r} (require 'complete')"}
    if rs.get("slug") != slug:
        return 1, {"run_state": f"slug={rs.get('slug')!r} != {slug!r}"}
    # green-unverified refusal (v0.37.0)
    gu = [s.get("id") for s in rs.get("slices", []) if s.get("status") == "green-unverified"]
    if gu:
        return 1, {"green_unverified": f"slices {gu} owe cross-model verification; cannot finalize"}

    rid = rs.get("run_id")
    comp = rs.get("completion")
    if not isinstance(comp, dict):
        return 1, {"completion": "missing terminal completion receipt (v0.37.1 requires it on complete)"}
    # (4) ISO timestamps — a present-but-unbound 't' is NOT freshness
    if not _is_iso(rs.get("updated_at")):
        return 1, {"freshness": f"updated_at={rs.get('updated_at')!r} is not an ISO-8601 timestamp"}
    if not _is_iso(comp.get("completed_at")):
        return 1, {"freshness": f"completion.completed_at={comp.get('completed_at')!r} is not an ISO-8601 timestamp"}
    # (5) run_id identity
    if comp.get("run_id") != rid:
        return 1, {"completion": f"completion.run_id {comp.get('run_id')!r} != run_state.run_id {rid!r}"}
    # (6) verified_tree identity + terminal event
    vt = rs.get("verified_tree")
    if comp.get("verified_tree") != vt:
        return 1, {"completion": f"completion.verified_tree {comp.get('verified_tree')!r} != run_state.verified_tree {vt!r}"}
    if comp.get("terminal_event") != "run_completed":
        return 1, {"completion": f"completion.terminal_event={comp.get('terminal_event')!r} (require 'run_completed')"}
    # (7) verified_tree == recomputed code-tree-hash of the committed ref
    got_tree = _code_tree_hash(repo, ref)
    if not got_tree or got_tree != vt:
        return 1, {"verified_tree": f"recomputed code-tree-hash {got_tree!r} != run_state.verified_tree {vt!r}"}

    # (8-11) run-evidence.json present + schema-valid + identity + status
    ev_bytes = _git_show_bytes(repo, ref, f".parallax/{slug}/evidence/run-evidence.json")
    if ev_bytes is None:
        return 1, {"evidence": f"missing committed .parallax/{slug}/evidence/run-evidence.json"}
    try:
        rev = json.loads(ev_bytes.decode("utf-8", "replace"))
    except Exception as e:
        return 1, {"evidence": f"run-evidence.json bad json: {e}"}
    rerr = _validate(rev, _SCHEMA_RUNEVIDENCE)
    if rerr:
        return 1, {"evidence": f"run-evidence.json {rerr}"}
    run = rev.get("run", {}) if isinstance(rev.get("run"), dict) else {}
    if run.get("run_id") != rid:
        return 1, {"evidence": f"run-evidence.run.run_id {run.get('run_id')!r} != run_state.run_id {rid!r}"}
    if run.get("slug") != slug:
        return 1, {"evidence": f"run-evidence.run.slug {run.get('slug')!r} != {slug!r}"}
    if run.get("status") != "complete":
        return 1, {"evidence": f"run-evidence.run.status {run.get('status')!r} != 'complete'"}

    # (12-14) events.jsonl present + every line schema-valid + a same-run run_completed event
    evt_bytes = _git_show_bytes(repo, ref, f".parallax/{slug}/evidence/events.jsonl")
    if evt_bytes is None:
        return 1, {"evidence": f"missing committed .parallax/{slug}/evidence/events.jsonl"}
    saw_terminal = False
    iter_events = 0
    for i, line in enumerate(evt_bytes.decode("utf-8", "replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except Exception as e:
            return 1, {"events": f"line {i} bad json: {e}"}
        everr = _validate(ev, _SCHEMA_EVENT)
        if everr:
            return 1, {"events": f"line {i} {everr}"}
        if ev.get("event_type") == "run_completed" and ev.get("run_id") == rid and ev.get("slug") == slug:
            saw_terminal = True
        if ev.get("event_type") == "arbiter_iteration_started":
            iter_events += 1
    if not saw_terminal:
        return 1, {"events": f"no run_completed event with run_id={rid!r} slug={slug!r}"}
    # (14b, v0.38 D1) iteration self-audit — the RUN1 timeline logged 5 arbiter_iteration_started
    # for 14 actual iterations. FLAG (never hold) when run-state's own counters exceed the logged
    # events, so an auditor trusting events.jsonl alone learns it under-counts.
    iter_claimed = sum(int(s.get("iterations") or 0) for s in rs.get("slices", []))
    telemetry_warning = None
    if iter_claimed > iter_events:
        telemetry_warning = (f"run-state claims {iter_claimed} arbiter iterations but events.jsonl "
                             f"logs only {iter_events} arbiter_iteration_started — per-iteration "
                             "event emission was incomplete (v0.38 D1 self-audit; non-blocking)")

    # (15) committed evidence byte hashes == completion.*_sha256
    rev_sha = hashlib.sha256(ev_bytes).hexdigest()
    evt_sha = hashlib.sha256(evt_bytes).hexdigest()
    if comp.get("run_evidence_sha256") != rev_sha:
        return 1, {"evidence_hash": f"run-evidence.json sha256 {rev_sha} != completion {comp.get('run_evidence_sha256')!r}"}
    if comp.get("events_jsonl_sha256") != evt_sha:
        return 1, {"evidence_hash": f"events.jsonl sha256 {evt_sha} != completion {comp.get('events_jsonl_sha256')!r}"}

    # (16) lock, if a non-null object, must belong to this run_id
    lock = rs.get("lock")
    if isinstance(lock, dict) and lock.get("holder") not in (None, rid):
        return 1, {"lock": f"lock.holder {lock.get('holder')!r} belongs to a different run than {rid!r}"}

    # (17a) per-slice arbiter receipts (v0.37.0)
    arb = {}
    for s in rs.get("slices", []):
        sid = s.get("id")
        araw = _git_show(repo, ref, f".parallax/{slug}/arbiter/{sid}.json")
        if araw is None:
            arb[sid] = "no committed arbiter receipt"; continue
        try:
            ar = json.loads(araw)
        except Exception as e:
            arb[sid] = f"bad json: {e}"; continue
        verr = _validate(ar, _SCHEMA_ARBITER)
        if verr:
            arb[sid] = verr; continue
        if ar.get("slug") != slug or ar.get("slice_id") != sid:
            arb[sid] = "arbiter receipt identity mismatch"; continue
        if ar.get("verdict") != "green":
            arb[sid] = f"arbiter verdict={ar.get('verdict')!r} (require 'green')"; continue
        want = s.get("verified_diff")
        if want and ar.get("verified_diff") != want:
            arb[sid] = f"arbiter verified_diff {ar.get('verified_diff')!r} != run-state {want!r}"; continue
        arb[sid] = "green"
    bad = {k: v for k, v in arb.items() if v != "green"}
    if bad:
        return 1, {"arbiter_receipts": bad}

    # (18, v0.38 D2) the whole-feature sweep must be RECEIPTED, not prose. The RUN1 terminal
    # event said "feature-sweep clean" with empty artifact_paths and nothing on disk — from
    # v0.38 completion requires a committed, schema-valid sweep receipt whose verdict is clean
    # and whose manifest_sha256 matches the committed invariants.json bytes.
    sw_raw = _git_show(repo, ref, f".parallax/{slug}/sweep-receipt.json")
    if sw_raw is None:
        return 1, {"sweep": f"no committed .parallax/{slug}/sweep-receipt.json — 'feature-sweep "
                            "clean' as prose is not a receipt (v0.38 D2)"}
    try:
        sw = json.loads(sw_raw)
    except Exception as e:
        return 1, {"sweep": f"bad json: {e}"}
    swerr = _validate(sw, _SCHEMA_SWEEP)
    if swerr:
        return 1, {"sweep": swerr}
    if sw.get("slug") != slug:
        return 1, {"sweep": f"receipt slug {sw.get('slug')!r} != {slug!r}"}
    if sw.get("verdict") != "clean":
        return 1, {"sweep": f"receipt verdict {sw.get('verdict')!r} != 'clean'"}
    inv_bytes = _git_show_bytes(repo, ref, f".parallax/{slug}/invariants.json")
    if inv_bytes is None:
        return 1, {"sweep": "receipt present but no committed invariants.json to bind it to"}
    if sw.get("manifest_sha256") != hashlib.sha256(inv_bytes).hexdigest():
        return 1, {"sweep": "receipt manifest_sha256 != committed invariants.json (the sweep ran "
                            "against a different manifest)"}

    # (17b) delegate the deep verifier/contract/tree/slice-set checks to epic-gate.py
    p = subprocess.run(
        ["python3", _EPIC_GATE, "--feature-ref", ref, "--slug", slug, "--repo", repo],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return 1, {"epic_gate": "hold", "detail": (p.stdout.strip() or p.stderr.strip())}

    out = {"verdict": "finalize-ok", "freshness": "bound",
           "arbiter_receipts": "all-green", "sweep": "receipted-clean", "epic_gate": "verified"}
    if telemetry_warning:
        out["telemetry_warning"] = telemetry_warning
    return 0, out


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37.1 standalone finalize gate (freshness-bound).")
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
