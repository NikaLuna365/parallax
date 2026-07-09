#!/usr/bin/env python3
"""Parallax auditable frozen-contract tightening guard (v0.37 P0.4).

The Parallax promise depends on one stable, reviewed behavioural contract. Real runs,
though, often discover a determinate mechanical under-scope after freeze (the spec left
exactly one correct reading implicit). /parallax:resolve is too heavy for that, and an
in-place frozen-spec edit silently breaks the reviewed-contract promise. This guard adds
a SANCTIONED, bounded, auditable amendment path and rejects every other post-freeze change.

`verify`  — given the frozen contract hash and the current contract bytes at a ref, decide:
            * current == frozen                  -> ok (unchanged).
            * current reachable from frozen via a continuous prev->new chain of valid
              amendment records (kind=mechanical-tightening, evidence present, prefreeze
              review pass/low-notes, all propagation flags true) -> ok (sanctioned).
            * otherwise                            -> REJECT (post-freeze mutation outside
              the sanctioned path).
`record`  — append a well-formed amendment record (helper for the orchestrator).

The frozen hash comes from `--frozen-hash` or, if omitted, the committed
`.parallax/<slug>/contract.frozen` at the ref. The current contract hash is recomputed
with scripts/contract-hash.sh (spec.md + slices.md + validation.md + slices.lock).

Exit (verify): 0 ok (unchanged or sanctioned), 2 rejected (unsanctioned mutation),
3 bad input (fail-closed). record: 0 written, 3 bad input.
"""
import argparse
import glob
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_CONTRACT_HASH_SH = os.path.join(_HERE, "contract-hash.sh")
_SCHEMA = os.path.join(_HERE, "..", "assets", "contract-amendment.schema.json")
_PROP_KEYS = ["examples", "acceptance", "public_interface", "blast_radius", "validation", "slice_seams"]


def _git_show(repo, ref, path):
    p = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def _contract_hash(repo, ref, slug):
    p = subprocess.run(["bash", _CONTRACT_HASH_SH, ref, slug, repo], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _validate(doc):
    try:
        import jsonschema
    except ImportError:
        return None  # structural checks below still apply
    try:
        jsonschema.validate(doc, json.load(open(_SCHEMA)))
        return None
    except Exception as e:
        return f"schema-invalid: {getattr(e, 'message', e)}"


def _amend_ok(a, slug):
    """Structural + policy validity of one amendment record (independent of jsonschema)."""
    err = _validate(a)
    if err:
        return err
    if a.get("slug") != slug:
        return f"slug={a.get('slug')!r} != {slug!r}"
    if a.get("kind") != "mechanical-tightening":
        return f"kind={a.get('kind')!r} (only 'mechanical-tightening' is sanctioned)"
    if not a.get("evidence"):
        return "no evidence (a tightening must be evidence-backed)"
    pr = a.get("prefreeze_review") or {}
    if pr.get("verdict") not in ("pass", "low-notes"):
        return f"prefreeze_review.verdict={pr.get('verdict')!r} (require pass/low-notes)"
    prop = a.get("propagation") or {}
    missing = [k for k in _PROP_KEYS if prop.get(k) is not True]
    if missing:
        return f"propagation incomplete: {missing} not all true"
    if not a.get("prev_contract_hash") or not a.get("new_contract_hash"):
        return "missing prev/new contract hash"
    return None


def _load_amendments(repo, ref, slug):
    """Committed amendment records at the ref (or working tree if ref is None)."""
    recs = []
    if ref is None:
        for p in sorted(glob.glob(os.path.join(repo, ".parallax", slug, "amendments", "*.json"))):
            try:
                recs.append((os.path.basename(p), json.load(open(p))))
            except Exception as e:
                recs.append((os.path.basename(p), {"__bad__": str(e)}))
        return recs
    # committed: list tree then show each
    p = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", ref,
                        f".parallax/{slug}/amendments"], capture_output=True, text=True)
    for path in [l for l in p.stdout.splitlines() if l.endswith(".json")]:
        raw = _git_show(repo, ref, path)
        try:
            recs.append((os.path.basename(path), json.loads(raw)))
        except Exception as e:
            recs.append((os.path.basename(path), {"__bad__": str(e)}))
    return recs


def verify(repo, ref, slug, frozen_hash):
    if frozen_hash is None:
        fh = _git_show(repo, ref, f".parallax/{slug}/contract.frozen") if ref else None
        if fh is None and ref is None:
            fp = os.path.join(repo, ".parallax", slug, "contract.frozen")
            fh = open(fp).read() if os.path.exists(fp) else None
        frozen_hash = (fh or "").strip() or None
    if not frozen_hash:
        return 3, {"frozen": "no frozen contract hash (pass --frozen-hash or commit .parallax/<slug>/contract.frozen)"}
    current = _contract_hash(repo, ref or "HEAD", slug)
    if not current:
        return 3, {"contract": "could not recompute current contract hash"}
    if current == frozen_hash:
        return 0, {"verdict": "unchanged", "contract_hash": current}

    # build chain from amendments
    recs = _load_amendments(repo, ref, slug)
    by_prev = {}
    for name, a in recs:
        if "__bad__" in a:
            return 2, {"verdict": "rejected", "reason": f"bad amendment {name}: {a['__bad__']}"}
        # v0.38 5.2 — review-BUDGET amendments (parallax-review-budget-amendment-v1) live in the
        # same amendments/ directory but belong to the POLICY chain (scripts/budget_chain.py),
        # never to the contract-bytes chain: skip them here, exactly as budget_chain skips
        # contract tightenings. The v0.37 P0.4 rule is untouched — only mechanical-tightening
        # records can move contract bytes.
        if a.get("schema_version") == "parallax-review-budget-amendment-v1" \
                or a.get("kind") == "review-budget-amendment":
            continue
        err = _amend_ok(a, slug)
        if err:
            return 2, {"verdict": "rejected", "reason": f"invalid amendment {name}: {err}"}
        prev = a["prev_contract_hash"]
        if prev in by_prev:
            return 2, {"verdict": "rejected", "reason": f"ambiguous chain: two amendments tighten from {prev[:12]}"}
        by_prev[prev] = a
    cur = frozen_hash
    seen = set()
    steps = []
    while cur != current:
        if cur in seen:
            return 2, {"verdict": "rejected", "reason": "amendment chain cycle"}
        seen.add(cur)
        a = by_prev.get(cur)
        if a is None:
            return 2, {"verdict": "rejected",
                       "reason": f"post-freeze contract change with no sanctioned amendment from {cur[:12]} (current {current[:12]})"}
        steps.append(a["amendment_id"])
        cur = a["new_contract_hash"]
    return 0, {"verdict": "sanctioned-tightening", "chain": steps, "contract_hash": current}


def record(args):
    out_dir = os.path.join(args.repo, ".parallax", args.slug, "amendments")
    os.makedirs(out_dir, exist_ok=True)
    rec = {
        "schema_version": "parallax-contract-amendment-v1",
        "slug": args.slug,
        "amendment_id": args.amendment_id,
        "kind": "mechanical-tightening",
        "rationale": args.rationale,
        "evidence": args.evidence,
        "prev_contract_hash": args.prev_hash,
        "new_contract_hash": args.new_hash,
        "prefreeze_review": {"verdict": args.prefreeze_verdict, "notes": args.prefreeze_notes,
                             "artifact": args.prefreeze_artifact},
        "propagation": {k: True for k in _PROP_KEYS},
    }
    err = _amend_ok(rec, args.slug)
    if err:
        print(json.dumps({"error": err}))
        return 3
    path = os.path.join(out_dir, f"{args.amendment_id}.json")
    json.dump(rec, open(path, "w"), indent=2)
    print(json.dumps({"written": os.path.relpath(path, args.repo)}))
    return 0


def record_budget(args):
    """v0.38 5.2 (gates A3/A5) — record a sanctioned REVIEW-BUDGET amendment. The only way a
    frozen round budget may widen: a human repeats the machine-minted grant token for exactly
    this prev->new policy transition. A codex.toml edit is never authority."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "budget_chain", os.path.join(_HERE, "budget_chain.py"))
    bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
    from datetime import datetime, timezone
    try:
        new_policy = json.loads(args.new_policy)
    except Exception as e:
        print(json.dumps({"error": f"--new-policy must be a JSON [review] policy object: {e}"}))
        return 3
    rec = {
        "schema_version": "parallax-review-budget-amendment-v1",
        "slug": args.slug,
        "amendment_id": args.amendment_id,
        "kind": "review-budget-amendment",
        "rationale": args.rationale,
        "evidence": args.evidence,
        "prev_policy_hash": args.prev_policy_hash,
        "new_policy_hash": bc.policy_hash(new_policy),
        "new_policy": new_policy,
        "grant_token": args.grant_token,
        "approved_by": "human",
        "approved_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    try:
        bc.amendment_ok(rec, args.slug)   # schema + recomputed hash + machine-minted token match
    except bc.BudgetError as e:
        print(json.dumps({"error": str(e),
                          "expected_token": bc.expected_token(args.slug, args.amendment_id,
                                                              args.prev_policy_hash,
                                                              rec["new_policy_hash"])}))
        return 3
    out_dir = os.path.join(args.repo, ".parallax", args.slug, "amendments")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{args.amendment_id}.json")
    if os.path.exists(path):
        print(json.dumps({"error": f"{path} already exists; budget amendments are append-only"}))
        return 3
    json.dump(rec, open(path, "w"), indent=2)
    print(json.dumps({"written": os.path.relpath(path, args.repo),
                      "new_policy_hash": rec["new_policy_hash"]}))
    return 0


def verify_budget(args):
    """Resolve the EFFECTIVE review policy: pinned snapshot + committed BA-chain. Exit 0 with
    the effective policy, 2 on any invalid link / fork / tampered snapshot (fail closed)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "budget_chain", os.path.join(_HERE, "budget_chain.py"))
    bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
    pinned_path = args.pinned or os.path.join(args.repo, ".parallax", args.slug,
                                              "review-policy.frozen.json")
    try:
        frozen = json.load(open(pinned_path))
    except Exception as e:
        print(json.dumps({"verdict": "rejected", "reason": f"cannot read pinned policy {pinned_path}: {e}"}))
        return 2
    try:
        records = bc.load_amendment_files(os.path.join(args.repo, ".parallax", args.slug, "amendments"))
        policy, phash, chain = bc.effective_policy(frozen, records, args.slug)
    except bc.BudgetError as e:
        print(json.dumps({"verdict": "rejected", "reason": str(e)}))
        return 2
    print(json.dumps({"verdict": "effective", "policy": policy, "policy_hash": phash, "chain": chain}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37 frozen-contract tightening guard (+ v0.38 review-budget amendments).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--repo", default=".")
    v.add_argument("--ref", default=None, help="git ref to read committed contract+amendments (default: working tree)")
    v.add_argument("--slug", required=True)
    v.add_argument("--frozen-hash", default=None)
    r = sub.add_parser("record")
    r.add_argument("--repo", default=".")
    r.add_argument("--slug", required=True)
    r.add_argument("--amendment-id", required=True)
    r.add_argument("--rationale", required=True)
    r.add_argument("--evidence", action="append", required=True)
    r.add_argument("--prev-hash", required=True)
    r.add_argument("--new-hash", required=True)
    r.add_argument("--prefreeze-verdict", default="pass", choices=["pass", "low-notes"])
    r.add_argument("--prefreeze-notes", default=None)
    r.add_argument("--prefreeze-artifact", default=None)
    rb = sub.add_parser("record-budget",
                        help="v0.38 5.2: record a sanctioned review-budget widening (BA-<n>)")
    rb.add_argument("--repo", default=".")
    rb.add_argument("--slug", required=True)
    rb.add_argument("--amendment-id", required=True, help="BA-<n>")
    rb.add_argument("--rationale", required=True)
    rb.add_argument("--evidence", action="append", required=True)
    rb.add_argument("--prev-policy-hash", required=True,
                    help="pinned policy_hash (or the previous BA's new_policy_hash)")
    rb.add_argument("--new-policy", required=True,
                    help='JSON object: {"max_rounds":3,"block_severities":[...],"advisory_severities":[...],"always_block_kinds":[...]}')
    rb.add_argument("--grant-token", required=True,
                    help="the machine-minted token the HUMAN explicitly repeated (budget_chain.expected_token)")
    vb = sub.add_parser("verify-budget",
                        help="v0.38 5.2: resolve the effective policy from pinned snapshot + BA-chain")
    vb.add_argument("--repo", default=".")
    vb.add_argument("--slug", required=True)
    vb.add_argument("--pinned", default=None, help="override path to review-policy.frozen.json")
    a = ap.parse_args(argv)
    if a.cmd == "verify":
        code, detail = verify(a.repo, a.ref, a.slug, a.frozen_hash)
        print(json.dumps(detail))
        return code
    if a.cmd == "record-budget":
        return record_budget(a)
    if a.cmd == "verify-budget":
        return verify_budget(a)
    return record(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
