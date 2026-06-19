#!/usr/bin/env python3
"""Parallax review-ledger merge — the ONLY writer of a per-slice review ledger.

The cross-model verifier emits a review ROUND (assets/codex/review-round.schema.json): the
findings it currently sees + the prior findings it has positively re-verified as resolved.
This script merges that round into the per-slice ledger mechanically, so the orchestrating
Claude NEVER authors findings, ids, spec_refs or lifecycle transitions itself (that would be
the producer certifying itself — exactly what Parallax forbids).

Mechanical rules:
  * fingerprint = sha256( kind | spec_ref | file(where) )[:16]  — stable across rephrasings and
    line-number shifts (we key on the FILE in `where`, not the line), so the same defect maps to
    the same ledger id across rounds instead of spawning a new one.
  * a round finding whose fingerprint already exists  -> update it; if it was `fixed`, it is now
    `regressed` (the fix didn't hold). Otherwise it stays/returns to `open`.
  * a round finding with a new fingerprint            -> new id  S<slice>-N<k>, status `open`.
  * a `resolved` entry (positive Codex confirmation) whose fingerprint is NOT in the current
    findings  -> that ledger finding becomes `fixed`, verified_by="codex",
    last_verified_diff=<current diff>. ABSENCE ALONE NEVER fixes a finding (fail closed).
  * rounds_used += 1  (one merge == one completed verifier round; the initial post-green review
    is round 1, so [review].max_rounds = 2 permits at most two verifier invocations).

Usage:
    merge-ledger.py LEDGER.json ROUND.json --slice S1 --current-diff <sha> [--slug <slug>]
LEDGER.json is created if absent. Writes the updated ledger back to LEDGER.json.
"""
import argparse, hashlib, json, os, re, sys


def _file_of(where):
    """The stable part of a location: the file path, dropping :line[:col] and surrounding noise."""
    w = (where or "").strip()
    return re.split(r"[:#]", w, 1)[0].strip().lower()


def fingerprint(kind, spec_ref, where):
    basis = "|".join([(kind or "").strip().lower(), (spec_ref or "").strip().lower(), _file_of(where)])
    return hashlib.sha256(basis.encode()).hexdigest()[:16]


def _next_n(findings, slice_id):
    n = 0
    for f in findings:
        m = re.match(rf"^{re.escape(slice_id)}-N(\d+)$", f.get("id", ""))
        if m:
            n = max(n, int(m.group(1)))
    return n + 1


def merge(ledger, rnd, slice_id, current_diff, slug=None):
    ledger.setdefault("slug", slug or ledger.get("slug", "?"))
    ledger.setdefault("slice_id", slice_id)
    ledger.setdefault("rounds_used", 0)
    findings = ledger.setdefault("findings", [])
    by_fp = {f.get("fingerprint"): f for f in findings if f.get("fingerprint")}
    round_no = ledger["rounds_used"] + 1

    current_fps = set()
    for item in rnd.get("findings", []):
        fp = fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))
        current_fps.add(fp)
        ex = by_fp.get(fp)
        if ex:                                   # known defect resurfaced / persists
            if ex.get("status") == "fixed":
                ex["status"] = "regressed"       # the fix didn't hold
            elif ex.get("status") != "regressed":
                ex["status"] = "open"
            ex["severity"] = item.get("severity", ex.get("severity"))
            ex["claim"] = item.get("claim", ex.get("claim"))
            ex["evidence"] = item.get("evidence", ex.get("evidence"))
            ex["last_verified_diff"] = current_diff
            if item.get("functional_repro") is not None:
                ex["functional_repro"] = bool(item["functional_repro"])
        else:                                    # genuinely new
            nid = f"{slice_id}-N{_next_n(findings, slice_id)}"
            nf = {
                "id": nid, "fingerprint": fp,
                "severity": item.get("severity"), "kind": item.get("kind"),
                "spec_ref": item.get("spec_ref"), "where": item.get("where", ""),
                "claim": item.get("claim", ""), "evidence": item.get("evidence", ""),
                "status": "open", "round": round_no,
                "first_seen_diff": current_diff, "last_verified_diff": current_diff,
            }
            if item.get("functional_repro"):
                nf["functional_repro"] = True
            findings.append(nf); by_fp[fp] = nf

    # positive resolutions — ONLY for findings the verifier confirms AND that are not also current
    for item in rnd.get("resolved", []):
        fp = fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))
        if fp in current_fps:
            continue                             # it's still being reported -> not resolved
        ex = by_fp.get(fp)
        if ex and ex.get("status") in ("open", "regressed"):
            ex["status"] = "fixed"
            ex["verified_by"] = "codex"
            ex["last_verified_diff"] = current_diff
            ex["resolution"] = item.get("note", "verified resolved by codex")

    ledger["rounds_used"] = round_no
    return ledger


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("ledger"); ap.add_argument("round")
    ap.add_argument("--slice", dest="slice_id", required=True)
    ap.add_argument("--current-diff", dest="current_diff", required=True)
    ap.add_argument("--slug")
    a = ap.parse_args(argv)
    ledger = json.load(open(a.ledger)) if os.path.exists(a.ledger) else {}
    rnd = json.load(open(a.round)) if a.round != "-" else json.loads(sys.stdin.read())
    out = merge(ledger, rnd, a.slice_id, a.current_diff, a.slug)
    if a.ledger != "-":
        os.makedirs(os.path.dirname(a.ledger) or ".", exist_ok=True)
        json.dump(out, open(a.ledger, "w"), indent=2)
    print(json.dumps({"slice_id": out["slice_id"], "rounds_used": out["rounds_used"],
                      "findings": len(out["findings"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
