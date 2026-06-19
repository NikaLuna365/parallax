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
    It GROUPS occurrences of a defect; it is NOT a unique id (two genuinely-different defects can
    share one kind|spec_ref|file). So matching is two-pass: (A) a round finding that cites an exact
    ledger id (`findings[].id`, echoed from the prior findings handed to the verifier) binds to THAT
    finding — unambiguous even when fingerprints collide; (B) an uncited finding takes the first
    still-unconsumed ledger finding of its fingerprint, else becomes a NEW, distinct finding. So two
    different findings reported in one round never collapse into a single entry (the v0.21 P1#4 data
    loss, where the first of two same-section defects was silently overwritten and lost).
  * a matched existing finding  -> if it was `fixed`, it becomes `regressed` (the fix didn't hold);
    otherwise it stays/returns to `open`.
  * an uncited round finding with no free same-fp slot  -> new id  S<slice>-N<k>, status `open`.
  * a `resolved` entry (positive Codex confirmation) is matched by EXACT ledger id when the verifier
    cites one (`resolved[].id`, echoed from the prior findings it was handed) — unambiguous even when
    fingerprints collide; else it falls back to the first still-live finding of that fingerprint. It
    NEVER settles a finding also re-reported this round; ABSENCE ALONE NEVER fixes one (fail closed).
    The settled finding becomes `fixed`, verified_by="codex", last_verified_diff=<current diff>.
  * rounds_used += 1  (one merge == one completed verifier round; the initial post-green review
    is round 1, so [review].max_rounds = 2 permits at most two verifier invocations).

Usage:
    merge-ledger.py LEDGER.json ROUND.json --slice S1 --current-diff <sha> [--slug <slug>]
LEDGER.json is created if absent. Writes the updated ledger back to LEDGER.json.
"""
import argparse, hashlib, json, os, re, sys
from collections import defaultdict


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
    round_no = ledger["rounds_used"] + 1

    # fingerprint GROUPS occurrences (it is NOT unique) -> map each fp to the LIST of its ledger
    # findings, in ledger order, so a round's k-th occurrence matches the k-th existing one.
    by_fp = defaultdict(list)
    by_id = {}
    for f in findings:
        if f.get("fingerprint"):
            by_fp[f["fingerprint"]].append(f)
        if f.get("id"):
            by_id[f["id"]] = f

    consumed = set()               # ledger ids already matched to a round finding this round
    current_ids = set()            # ledger ids re-reported or created this round (still live)

    def _reopen(ex, item):
        if ex.get("status") == "fixed":
            ex["status"] = "regressed"           # the fix didn't hold
        elif ex.get("status") != "regressed":
            ex["status"] = "open"
        ex["severity"] = item.get("severity", ex.get("severity"))
        ex["claim"] = item.get("claim", ex.get("claim"))
        ex["evidence"] = item.get("evidence", ex.get("evidence"))
        ex["last_verified_diff"] = current_diff
        if item.get("functional_repro") is not None:
            ex["functional_repro"] = bool(item["functional_repro"])
        consumed.add(ex["id"]); current_ids.add(ex["id"])

    # Pass A — a round finding that cites an exact ledger id binds to THAT finding (unambiguous even
    # when fingerprints collide). Uncited findings defer to fingerprint matching.
    deferred = []
    for item in rnd.get("findings", []):
        rid = item.get("id")
        if rid and rid in by_id and rid not in consumed:
            _reopen(by_id[rid], item)
        else:
            deferred.append(item)
    # Pass B — each uncited finding takes the FIRST still-unconsumed ledger finding of its fingerprint;
    # if none remains it becomes a NEW, distinct finding. So two same-fp findings in one round never
    # collapse — each consumes a different slot, or spawns its own id (the v0.21 P1#4 data loss).
    for item in deferred:
        fp = fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))
        avail = [f for f in by_fp[fp] if f["id"] not in consumed]
        if avail:
            _reopen(avail[0], item)
        else:
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
            findings.append(nf); by_fp[fp].append(nf); by_id[nid] = nf
            consumed.add(nid); current_ids.add(nid)

    # positive resolutions: prefer the EXACT cited ledger id (unambiguous when fingerprints collide);
    # otherwise fall back to the first still-live finding of that fingerprint. NEVER settle a finding
    # also re-reported this round, and absence alone never fixes anything (fail closed).
    for item in rnd.get("resolved", []):
        target = None
        rid = item.get("id")
        if rid and rid in by_id:
            cand = by_id[rid]
            if cand["id"] not in current_ids and cand.get("status") in ("open", "regressed"):
                target = cand
        else:
            fp = fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))
            for cand in by_fp.get(fp, []):
                if cand["id"] not in current_ids and cand.get("status") in ("open", "regressed"):
                    target = cand
                    break
        if target:
            target["status"] = "fixed"
            target["verified_by"] = "codex"
            target["last_verified_diff"] = current_diff
            target["resolution"] = item.get("note", "verified resolved by codex")

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
