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

  * path canonicalization (v0.37.3 F4): the `file` component of `where` is free-text model
    output, and a later round may echo a basename (`StorageSubscreen.test.tsx:882`) where an
    earlier round recorded the repo-relative path — an exact-string fingerprint then treats
    ONE defect as two (phantom duplicate) and leaves the real one unresolved (the live-run F4
    failure). With `--repo-root`, the file component is canonicalized against the repo's
    TRACKED files before hashing: an exact tracked path stays itself; a unique path-suffix or
    unique basename resolves to its tracked repo-relative path; an AMBIGUOUS basename (two+
    tracked files share it) is NOT silently merged — it keeps its literal form, is reported
    in `path_warnings`, and printed to stderr, so a human sees the identity gap instead of a
    wrong merge. Existing ledger fingerprints are re-derived under the same canonicalization
    on load (ids never change — fingerprint is derived metadata), so pre-v0.37.3 ledgers
    converge instead of splitting. Without --repo-root, behavior is byte-identical to v0.37.2.

Usage:
    merge-ledger.py LEDGER.json ROUND.json --slice S1 --current-diff <sha> [--slug <slug>]
                    [--repo-root <path>]
LEDGER.json is created if absent. Writes the updated ledger back to LEDGER.json.
"""
import argparse, hashlib, json, os, re, subprocess, sys
from collections import defaultdict

# v0.37.3 F4 — module-level canonicalizer, installed by main() when --repo-root is given.
# Threading it through _file_of keeps EVERY fingerprint call site (pass A id-consistency,
# pass B grouping, resolved fallback, ledger re-derivation) on one identical path form.
_CANON = None
_PATH_WARNINGS = []


class PathIndexError(Exception):
    pass


def build_canonicalizer(repo_root):
    """Index the repo's tracked files (git ls-files) for canonical path resolution.
    Fail closed on a broken index: the caller explicitly asked for repo-anchored identity,
    so a missing repo must be a hard error, never a silent fall-back to string matching."""
    p = subprocess.run(["git", "-C", repo_root, "ls-files"], capture_output=True, text=True)
    if p.returncode != 0:
        raise PathIndexError(f"git ls-files failed in {repo_root!r}: {p.stderr.strip()}")
    tracked = [l.strip() for l in p.stdout.splitlines() if l.strip()]
    exact = {t.lower() for t in tracked}
    by_base = defaultdict(set)
    for t in tracked:
        by_base[os.path.basename(t).lower()].add(t.lower())

    def canon(file_lower):
        f = file_lower.lstrip("./") if file_lower.startswith("./") else file_lower
        if not f:
            return f
        if f in exact:                                   # already a tracked repo-relative path
            return f
        suffix = {t for t in exact if t.endswith("/" + f)}
        if len(suffix) == 1:                             # unique partial path (sub-path drift)
            return next(iter(suffix))
        cands = by_base.get(os.path.basename(f), set()) if len(suffix) == 0 else suffix
        if len(cands) == 1:                              # unique basename
            return next(iter(cands))
        if len(cands) > 1:                               # ambiguous: NEVER silently merge
            w = f"ambiguous path {f!r} matches {sorted(cands)}; kept distinct (not canonicalized)"
            if w not in _PATH_WARNINGS:
                _PATH_WARNINGS.append(w)
                print(f"WARNING: {w}", file=sys.stderr)
        return f                                         # unknown/ambiguous: keep literal form

    return canon


def _file_of(where):
    """The stable part of a location: the file path, dropping :line[:col] and surrounding
    noise — canonicalized to a tracked repo-relative path when --repo-root is active (F4)."""
    w = (where or "").strip()
    f = re.split(r"[:#]", w, 1)[0].strip().lower()
    return _CANON(f) if _CANON else f


def fingerprint(kind, spec_ref, where):
    basis = "|".join([(kind or "").strip().lower(), (spec_ref or "").strip().lower(), _file_of(where)])
    return hashlib.sha256(basis.encode()).hexdigest()[:16]


def _id_consistent(ex, item):
    """A cited id is honored ONLY if it agrees with the item's fingerprint (kind|spec_ref|file).
    Without this, a round could resolve or re-report finding A by quoting A's id while carrying a
    completely different defect's metadata — closing the wrong finding (v0.22 P1#3). On a mismatch we
    ignore the id and fall back to fingerprint matching, which is fail-safe (it can't settle A)."""
    return ex.get("fingerprint") == fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))


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
        if rid and rid in by_id and rid not in consumed and _id_consistent(by_id[rid], item):
            _reopen(by_id[rid], item)
        else:
            deferred.append(item)                # uncited, or an id whose metadata doesn't match it
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
        rid = item.get("id")
        cand = by_id.get(rid) if rid else None
        if cand and _id_consistent(cand, item) and cand["id"] not in current_ids:
            # Exact, consistent id: settle a LIVE finding, OR re-stamp an ALREADY-`fixed` one the verifier
            # re-confirmed against the CURRENT tree. The re-stamp keeps a fix's proof tracking the latest
            # diff across rounds (while sibling findings are still being fixed), so it doesn't read as
            # stale at the final green — the verifier's regression pass re-confirms every fixed finding.
            if cand.get("status") in ("open", "regressed"):
                cand["status"] = "fixed"
                cand["resolution"] = item.get("note", "verified resolved by codex")
            cand["verified_by"] = "codex"
            cand["last_verified_diff"] = current_diff
            continue
        # no id, or an id whose metadata doesn't match -> fingerprint fallback: settle the first LIVE match only
        fp = fingerprint(item.get("kind"), item.get("spec_ref"), item.get("where"))
        for c in by_fp.get(fp, []):
            if c["id"] not in current_ids and c.get("status") in ("open", "regressed"):
                c["status"] = "fixed"
                c["verified_by"] = "codex"
                c["last_verified_diff"] = current_diff
                c["resolution"] = item.get("note", "verified resolved by codex")
                break

    ledger["rounds_used"] = round_no
    return ledger


_ROUND_SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "assets", "codex", "review-round.schema.json")


def _load_budget_chain():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "budget_chain",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "budget_chain.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("ledger"); ap.add_argument("round")
    ap.add_argument("--slice", dest="slice_id", required=True)
    ap.add_argument("--current-diff", dest="current_diff", required=True)
    ap.add_argument("--slug")
    ap.add_argument("--policy", help="trusted .parallax/codex.toml — records the [review] policy_hash this ledger was triaged under (epic-gate.py checks it == the committed policy).")
    ap.add_argument("--pinned-policy", dest="pinned_policy",
                    help="v0.37.5 5.2 (gate A5): path to .parallax/<slug>/review-policy.frozen.json. "
                         "When given, the round BUDGET is enforced HERE at ingestion — a round beyond "
                         "the effective pinned budget (snapshot + recorded BA-* amendments) is refused "
                         "(exit 5), and policy_hash is stamped from the EFFECTIVE pinned policy, never "
                         "the live codex.toml.")
    ap.add_argument("--raw-response", dest="raw_response",
                    help="v0.37.5 5.3 (gate A4): path to the VERBATIM provider response for this round. "
                         "REQUIRED for a real merge: it must parse as JSON, equal the round content, "
                         "and it is persisted as <slice>.round<N>.raw.json next to the ledger before "
                         "the round is recorded — a verifier round with no re-readable raw receipt "
                         "does not exist. A malformed round/raw is a PROVIDER ERROR (retry/fallback), "
                         "never something to hand-extract a verdict from.")
    ap.add_argument("--contract-hash", dest="contract_hash", help="frozen hash of the normative spec contract (scripts/contract-hash.sh) — recorded into the ledger and frozen per run, like policy_hash.")
    ap.add_argument("--repo-root", dest="repo_root",
                    help="v0.37.3 F4: repository root whose TRACKED files anchor the file "
                         "component of `where` before fingerprinting — a basename echoed by a "
                         "later round then resolves to the same repo-relative path as round 1 "
                         "instead of minting a phantom duplicate. Ambiguous basenames are kept "
                         "distinct with a loud warning, never silently merged.")
    a = ap.parse_args(argv)
    global _CANON
    if a.repo_root:
        try:
            _CANON = build_canonicalizer(a.repo_root)
        except PathIndexError as exc:
            print(json.dumps({"error": f"path canonicalization unavailable: {exc}",
                              "detail": "--repo-root was requested; refusing to fall back to raw string identity"}))
            return 3
    ledger = json.load(open(a.ledger)) if os.path.exists(a.ledger) else {}
    try:
        rnd = json.load(open(a.round)) if a.round != "-" else json.loads(sys.stdin.read())
    except Exception as exc:
        print(json.dumps({"error": f"provider-error: round is not parseable JSON ({exc}) — retry the "
                                   "provider or fall back; NEVER hand-extract a verdict from a "
                                   "malformed envelope (v0.37.5 5.3)"}))
        return 2
    # v0.37.5 5.3 (gate A4) — the ledger ingests ONLY a schema-valid round backed by a persisted
    # verbatim raw response. The RUN1 live failure: a GLM envelope crashed the parser and the
    # orchestrator hand-authored the "pass" that reached this script. Now: (1) the round must
    # validate against review-round.schema.json (a malformed/hand-extracted verdict is a
    # provider error — retry/fallback, never a pass); (2) --raw-response is mandatory, must
    # equal the round content, and is persisted as <slice>.round<N>.raw.json BEFORE the round
    # is recorded, symmetric with pre-freeze — so every post-green verdict is independently
    # re-derivable post-hoc; (3) a receipt {round, raw_artifact, raw_sha256} is written into
    # the ledger, and triage/epic-gate refuse a ledger whose receipts don't cover its rounds.
    try:
        import jsonschema
        jsonschema.validate(rnd, json.load(open(_ROUND_SCHEMA)))
    except ImportError:
        print(json.dumps({"error": "jsonschema is required; refusing an unvalidated review round "
                                   "(fail closed, v0.37.5 5.3)"}))
        return 2
    except Exception as exc:
        print(json.dumps({"error": f"provider-error: round is not schema-valid "
                                   f"({getattr(exc, 'message', exc)}) — retry the provider or fall "
                                   "back; NEVER hand-author a verdict (v0.37.5 5.3)"}))
        return 2
    if not a.raw_response:
        print(json.dumps({"error": "provider raw response required (--raw-response): a verifier round "
                                   "with no persisted verbatim receipt is not auditable and does not "
                                   "count (v0.37.5 5.3, gate A4)"}))
        return 2
    try:
        raw_bytes = open(a.raw_response, "rb").read()
        if json.loads(raw_bytes.decode("utf-8")) != rnd:
            print(json.dumps({"error": "provider-error: --raw-response content does not equal the "
                                       "round being merged — the raw receipt must be the verbatim "
                                       "provider verdict, not a re-typed one (v0.37.5 5.3)"}))
            return 2
    except Exception as exc:
        print(json.dumps({"error": f"provider-error: cannot read/parse --raw-response ({exc}); a "
                                   "malformed envelope is a round FAILURE — retry or fall back "
                                   "(v0.37.5 5.3)"}))
        return 2
    if _CANON:
        # Re-derive every existing fingerprint under the SAME canonicalization (ids never
        # change — fingerprint is derived grouping metadata). A pre-v0.37.3 ledger whose
        # round-1 fingerprints were hashed from a different path form converges here, so the
        # canonical round being merged matches the old entry instead of splitting it.
        for f in ledger.get("findings", []):
            if f.get("fingerprint"):
                f["fingerprint"] = fingerprint(f.get("kind"), f.get("spec_ref"), f.get("where"))
    # v0.37.5 5.2 (gate A5) — the round BUDGET is enforced at ingestion against the PINNED
    # policy (+ its recorded BA-* amendment chain), never the live codex.toml. The RUN1 live
    # failure: an extra round was self-authorized by a bare assumption_recorded, and the
    # later HOLD was cleared by editing codex.toml. Now the round beyond the effective pinned
    # budget is refused HERE — widening first requires `contract-amend.py record-budget`
    # (a human-repeated machine-minted token), which this check then honors.
    new_policy_hash = None
    effective_policy = None
    chain_hashes = None
    if a.pinned_policy:
        bc = _load_budget_chain()
        try:
            frozen = json.load(open(a.pinned_policy))
            amend_dir = os.path.join(os.path.dirname(os.path.abspath(a.pinned_policy)), "amendments")
            if not os.path.isdir(amend_dir):
                amend_dir = os.path.normpath(os.path.join(
                    os.path.dirname(os.path.abspath(a.pinned_policy)), "..", "amendments"))
            records = bc.load_amendment_files(amend_dir)
            effective_policy, eff_hash, chain = bc.effective_policy(
                frozen, records, a.slug or frozen.get("slug"))
            # every hash ON the sanctioned chain (pinned + each amendment step) — a ledger
            # stamped at any of these is legitimate history; anything else is a swap.
            chain_hashes = {frozen["policy_hash"]}
            chain_hashes.update(r["new_policy_hash"] for r in bc.budget_records(records))
        except (OSError, ValueError, bc.BudgetError) as exc:
            print(json.dumps({"error": f"pinned-policy invalid (fail closed): {exc}"}))
            return 2
        next_round = int(ledger.get("rounds_used", 0)) + 1
        if next_round > int(effective_policy["max_rounds"]):
            print(json.dumps({"error": "round-budget-exhausted", "round": next_round,
                              "pinned_max_rounds": effective_policy["max_rounds"],
                              "chain": chain,
                              "detail": "the budget in force was PINNED at freeze; widening it "
                                        "requires a recorded review-budget amendment "
                                        "(contract-amend.py record-budget, human-repeated "
                                        "machine-minted token) — a codex.toml edit or an "
                                        "assumption_recorded is not authority (v0.37.5 5.2, gate A5)"}))
            return 5
        new_policy_hash = eff_hash
    elif a.policy:
        import triage as T
        pol, _ = T.load_policy(a.policy)
        new_policy_hash = T.policy_hash(pol)
    # FROZEN per run: both the [review] policy_hash and the normative contract_hash are recorded on round 1
    # and may NOT change on a later round. A mismatch means the policy was swapped (a permissive policy would
    # downgrade a prior `high` block to advisory — v0.25 P0#2) or the spec/validation contract was rewritten
    # after review (v0.26 P0). Either => refuse, PARK, require a fresh full review.
    for key, newval in (("policy_hash", new_policy_hash), ("contract_hash", a.contract_hash)):
        prior = ledger.get(key)
        if newval is not None and prior is not None and prior != newval:
            # v0.37.5 5.2 — ONE sanctioned exception to the v0.25 mid-run freeze: a policy_hash
            # transition whose PRIOR value sits on the recorded budget-amendment chain and whose
            # new value is the current effective hash. That is exactly a legitimate BA-* widening
            # taking effect mid-run; any other transition (incl. the RUN1 sed-edit) still PARKS.
            if key == "policy_hash" and chain_hashes is not None \
                    and prior in chain_hashes and newval == eff_hash:
                continue
            print(json.dumps({"error": f"{key}-changed-mid-run", "frozen": prior, "current": newval,
                              "detail": f"{key} is frozen per run; PARK and require a fresh full review"
                                        + (" (a policy change is sanctioned only via a recorded"
                                           " review-budget amendment)" if key == "policy_hash" else "")}))
            return 4
    out = merge(ledger, rnd, a.slice_id, a.current_diff, a.slug)
    if new_policy_hash is not None:               # round 1 records; later rounds confirmed-equal above
        out["policy_hash"] = new_policy_hash
    if a.contract_hash is not None:
        out["contract_hash"] = a.contract_hash
    # v0.37.5 5.3 — persist the verbatim raw response at its canonical name BEFORE recording the
    # receipt (symmetric with pre_freeze.round<N>.raw.json), then bind it into the ledger.
    round_no = out["rounds_used"]
    raw_name = f"{a.slice_id}.round{round_no}.raw.json"
    if a.ledger != "-":
        reviews_dir = os.path.dirname(os.path.abspath(a.ledger)) or "."
        os.makedirs(reviews_dir, exist_ok=True)
        raw_dst = os.path.join(reviews_dir, raw_name)
        if os.path.exists(raw_dst) and open(raw_dst, "rb").read() != raw_bytes:
            print(json.dumps({"error": f"refusing to overwrite a DIFFERENT raw receipt {raw_name} "
                                       "(append-only round history, v0.37.5 5.3)"}))
            return 2
        with open(raw_dst, "wb") as handle:
            handle.write(raw_bytes)
    receipts = out.setdefault("round_receipts", [])
    receipts.append({"round": round_no, "raw_artifact": raw_name,
                     "raw_sha256": hashlib.sha256(raw_bytes).hexdigest()})
    if a.ledger != "-":
        json.dump(out, open(a.ledger, "w"), indent=2)
    summary = {"slice_id": out["slice_id"], "rounds_used": out["rounds_used"],
               "findings": len(out["findings"]), "raw_receipt": raw_name}
    if _PATH_WARNINGS:
        summary["path_warnings"] = list(_PATH_WARNINGS)   # ambiguous paths kept distinct (F4) — loud, never silent
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
