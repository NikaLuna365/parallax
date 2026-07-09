#!/usr/bin/env python3
"""Parallax epic-advance gate — a FEATURE-LEVEL receipt bound to the actual promoted commit.

The gate decides whether `feature/<slug>` may auto-advance the append-only epic. It reads EVERYTHING
from the committed feature ref (never the working tree) and ties the decision to that exact commit, so
none of these slip through (v0.23 audit): an uncommitted/working-tree ledger, code changed after review,
an operator-narrowed slice list, a receipt whose identity doesn't match, or a "verified" with zero
verifier rounds.

For ref R = --feature-ref, the feature is VERIFIED iff ALL hold:
  1. run-state `git show R:.parallax/<slug>/run-state.json` exists, validates (fail-closed), status=="complete",
     and its own slug == --slug (receipts must belong to THIS feature, not another with matching ids).
  2. run-state.verified_tree == code-tree-hash(R) — the recomputed hash of every tracked non-.parallax/
     file at R. Binds the verdict to the ACTUAL committed tree: a code/test/config change after the run
     completed (which leaves the per-slice ledgers untouched) moves this hash => HOLD.
  3. the run-state slice set EQUALS the FROZEN, machine-readable manifest `git show R:.parallax/<slug>/slices.lock`
     EXACTLY — a run (or a tampered run-state) cannot drop or add a slice relative to the frozen spec.
  4. EVERY slice has status=="integrated"; each slice's ledger `git show R:.parallax/<slug>/reviews/<id>.json`
     exists, validates (fail-closed), has slug == --slug and slice_id == that id (identity), policy_hash ==
     the COMMITTED policy's hash AND contract_hash == the recomputed hash of the COMMITTED normative contract
     (spec/slices/validation/slices.lock — so neither the policy nor the spec was swapped after review),
     rounds_used >= 1 (a verifier actually ran), and triages GREEN against the diff its fixes were proven at.

v0.37.5 5.2 (gates A3/A5): the review policy/budget AUTHORITY is the committed freeze-time snapshot
`.parallax/<slug>/review-policy.frozen.json` plus its recorded review-budget-amendment chain
(BA-*.json) — never the live OR committed codex.toml. The committed codex.toml must hash-MATCH the
effective pinned policy or the gate HOLDS: a post-freeze `sed` of max_rounds (the RUN1 live bypass)
mismatches the pin, and re-stamped ledgers point at a hash no recorded amendment sanctions. run-state,
every ledger and slices.lock are validated fail-closed (no jsonschema / invalid => HOLD).
Exit: 0 verified (advance), 1 hold (do NOT advance), 3 bad input.

Usage:
    epic-gate.py --feature-ref <ref> --slug <slug> [--repo <dir>]
"""
import argparse, json, os, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import triage as T
import budget_chain as BC

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCHEMA_LEDGER     = os.path.join(_HERE, "..", "assets", "codex", "review-ledger.schema.json")
_SCHEMA_ROUND      = os.path.join(_HERE, "..", "assets", "codex", "review-round.schema.json")
_SCHEMA_RUNSTATE   = os.path.join(_HERE, "..", "assets", "run-state.schema.json")
_SCHEMA_SLICESLOCK = os.path.join(_HERE, "..", "assets", "slices-lock.schema.json")
_SCHEMA_FEATURE    = os.path.join(_HERE, "..", "assets", "feature-state.schema.json")
_TREE_HASH_SH      = os.path.join(_HERE, "code-tree-hash.sh")
_CONTRACT_HASH_SH  = os.path.join(_HERE, "contract-hash.sh")


def _git_show(repo, ref, path):
    """Contents of <path> AS COMMITTED at <ref>, or None if absent. Never touches the working tree."""
    p = subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def _code_tree_hash(repo, ref):
    p = subprocess.run(["bash", _TREE_HASH_SH, ref, repo], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _contract_hash(repo, ref, slug):
    p = subprocess.run(["bash", _CONTRACT_HASH_SH, ref, slug, repo], capture_output=True, text=True)
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


def _committed_policy(repo, ref):
    """Policy + its hash from the COMMITTED .parallax/codex.toml at <ref> (NOT the working tree, which an
    operator could swap to a permissive one at gate time — v0.24 P0#1). Absent => strict defaults."""
    raw = _git_show(repo, ref, ".parallax/codex.toml")
    if raw is None:
        pol, _ = T.load_policy(None)
        return pol, T.policy_hash(pol)
    fd, tmp = tempfile.mkstemp(suffix=".toml")
    try:
        os.write(fd, raw.encode()); os.close(fd)
        pol, _ = T.load_policy(tmp)
    finally:
        os.unlink(tmp)
    return pol, T.policy_hash(pol)


def gate(repo, ref, slug):
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
    if rs.get("slug") != slug:                                       # P1#4 — receipts must be THIS feature's
        return False, {"run_state": f"slug={rs.get('slug')!r} != {slug!r}"}

    # v0.31 safe-completion: if a feature-state ledger exists, the promoted run must be the ACTIVE generation
    # of a COMPLETE feature. A run-state with no contract_generation is treated as generation 1 (v0.30 compat).
    fs_raw = _git_show(repo, ref, f".parallax/{slug}/feature-state.json")
    if fs_raw is not None:
        try:
            fs = json.loads(fs_raw)
        except Exception as e:
            return False, {"feature_state": f"bad json: {e}"}
        ferr = _validate(fs, _SCHEMA_FEATURE)
        if ferr:
            return False, {"feature_state": ferr}
        if fs.get("slug") != slug:
            return False, {"feature_state": f"slug={fs.get('slug')!r} != {slug!r}"}
        if fs.get("status") != "complete":
            return False, {"feature_state": f"status={fs.get('status')!r} (require 'complete')"}
        if len(fs.get("resolution_chain", [])) != fs.get("generation", 1) - 1:
            return False, {"feature_state": "resolution_chain length != generation-1 (discontinuous)"}
        rs_gen = rs.get("contract_generation", 1)
        if rs_gen != fs.get("generation"):
            return False, {"feature_state": f"run-state generation {rs_gen} != active feature generation {fs.get('generation')} (stale-generation run)"}
        if rs.get("run_id") != fs.get("active_run_id"):
            return False, {"feature_state": f"run-state run_id {rs.get('run_id')!r} != active_run_id {fs.get('active_run_id')!r}"}
        if rs.get("feature_id") is not None and rs.get("feature_id") != fs.get("feature_id"):
            return False, {"feature_state": "run-state feature_id != feature-state feature_id"}

    # v0.37.5 5.2 (gates A3/A5) — the review budget/policy AUTHORITY is the freeze-time-frozen
    # snapshot + its recorded budget-amendment chain, both read COMMITTED at the ref. The
    # committed codex.toml is no longer authority — it must merely hash-MATCH the effective
    # pinned policy, so the RUN1 bypass (sed-edit max_rounds 2->3 post-hoc, re-stamp the
    # ledgers, commit) now fails closed twice over: the edited toml mismatches the pinned
    # hash, and the re-stamped ledgers point at a hash no recorded amendment sanctions.
    pin_raw = _git_show(repo, ref, f".parallax/{slug}/review-policy.frozen.json")
    if pin_raw is None:
        return False, {"pinned_policy": f"no committed .parallax/{slug}/review-policy.frozen.json — "
                                        "the round budget must be pinned at freeze (v0.37.5 5.2); "
                                        "a run without a pinned budget cannot be gated"}
    try:
        frozen = json.loads(pin_raw)
    except Exception as e:
        return False, {"pinned_policy": f"bad json: {e}"}
    # committed budget amendments (BA-*) at the ref — the ONLY sanctioned widening path
    p = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", ref,
                        f".parallax/{slug}/amendments"], capture_output=True, text=True)
    ba_records = []
    for path in [l for l in p.stdout.splitlines() if l.endswith(".json")]:
        raw = _git_show(repo, ref, path)
        try:
            ba_records.append(json.loads(raw))
        except Exception as e:
            return False, {"pinned_policy": f"bad amendment {path}: {e}"}
    try:
        policy, phash, ba_chain = BC.effective_policy(frozen, ba_records, slug)
        # every hash on the sanctioned chain: a ledger stamped at the pin or at any recorded
        # amendment step is legitimate history; a hash OUTSIDE the chain is a swap.
        chain_hashes = {frozen["policy_hash"]}
        chain_hashes.update(r["new_policy_hash"] for r in BC.budget_records(ba_records))
    except BC.BudgetError as e:
        return False, {"pinned_policy": f"budget authority invalid (fail closed): {e}"}
    # the committed codex.toml must MATCH the effective pinned policy — an edit is not authority
    _live_policy, live_hash = _committed_policy(repo, ref)
    if live_hash != phash:
        return False, {"pinned_policy": f"committed codex.toml policy hash {live_hash!r} != effective "
                                        f"pinned policy {phash!r} (chain {ba_chain or ['<none>']}) — "
                                        "editing codex.toml is not a budget amendment (v0.37.5 5.2)"}
    # frozen normative contract (spec/slices/validation/slices.lock) recomputed from the committed commit
    # (v0.26 P0) — each ledger's contract_hash must equal this, so the spec can't be rewritten after review.
    chash = _contract_hash(repo, ref, slug)
    if not chash:
        return False, {"contract": "could not recompute contract hash from the committed tree"}

    # bind to the actual committed tree (code changed after review => mismatch => hold)
    want = rs.get("verified_tree")
    got = _code_tree_hash(repo, ref)
    if not want or not got or want != got:
        return False, {"verified_tree": f"receipt {want!r} != recomputed {got!r} (code changed after review, or missing)"}

    # exact slice-set equality vs the FROZEN, machine-readable manifest (P0#2) — a run cannot drop a slice
    lockraw = _git_show(repo, ref, f".parallax/{slug}/slices.lock")
    if lockraw is None:
        return False, {"slices_lock": f"no committed .parallax/{slug}/slices.lock (frozen slice manifest)"}
    try:
        lock = json.loads(lockraw)
    except Exception as e:
        return False, {"slices_lock": f"bad json: {e}"}
    lerr = _validate(lock, _SCHEMA_SLICESLOCK)
    if lerr:
        return False, {"slices_lock": lerr}
    if lock.get("slug") != slug:
        return False, {"slices_lock": f"slug={lock.get('slug')!r} != {slug!r}"}
    frozen = set(lock.get("slices", []))
    rs_ids = set(s.get("id") for s in rs.get("slices", []))
    if frozen != rs_ids:
        return False, {"slices_lock": f"run-state slices {sorted(rs_ids)} != frozen {sorted(frozen)}"}

    results = {}
    verified = True
    for s in rs.get("slices", []):
        sid = s.get("id")
        if s.get("status") != "integrated":
            results[sid] = f"status={s.get('status')!r} (not integrated)"; verified = False; continue
        led_path = f".parallax/{slug}/reviews/{sid}.json"
        lraw = _git_show(repo, ref, led_path)
        if lraw is None:
            results[sid] = f"no committed {led_path}"; verified = False; continue
        try:
            ledger = json.loads(lraw)
        except Exception as e:
            results[sid] = f"bad ledger json: {e}"; verified = False; continue
        verr = _validate(ledger, _SCHEMA_LEDGER)
        if verr:
            results[sid] = verr; verified = False; continue
        if ledger.get("slug") != slug:                              # P1#4
            results[sid] = f"ledger slug={ledger.get('slug')!r} != {slug!r}"; verified = False; continue
        if ledger.get("slice_id") != sid:
            results[sid] = f"identity mismatch: ledger slice_id={ledger.get('slice_id')!r} != {sid!r}"; verified = False; continue
        if ledger.get("policy_hash") not in chain_hashes:           # P0#1 + v0.37.5 5.2: must sit ON the sanctioned chain
            results[sid] = (f"policy_hash {ledger.get('policy_hash')!r} is not on the sanctioned "
                            f"budget chain (pinned {frozen['policy_hash']!r} -> effective {phash!r}) — "
                            "a re-stamp not backed by a recorded amendment fails closed (v0.37.5 5.2)"); verified = False; continue
        if ledger.get("contract_hash") != chash:                    # v0.26 P0 — same spec/validation as committed
            results[sid] = f"contract_hash {ledger.get('contract_hash')!r} != committed-contract {chash!r}"; verified = False; continue
        if int(ledger.get("rounds_used", 0)) < 1:
            results[sid] = "rounds_used<1 (no verifier round ran)"; verified = False; continue
        # v0.37.5 5.3 (gate A4) — every round must be backed by a COMMITTED, sha256-matching,
        # schema-valid raw provider response. The receipts in the ledger alone are not proof:
        # re-read each raw file at the ref and re-derive both properties, so a hand-authored
        # verdict (the RUN1 S2 malformed-envelope extraction) cannot survive to the gate.
        rerr = T.receipts_cover_rounds(ledger)
        if rerr:
            results[sid] = rerr; verified = False; continue
        raw_bad = None
        for receipt in ledger.get("round_receipts", []):
            raw_path = f".parallax/{slug}/reviews/{receipt['raw_artifact']}"
            raw = _git_show(repo, ref, raw_path)
            if raw is None:
                raw_bad = f"receipt round {receipt['round']}: no committed {raw_path}"; break
            import hashlib as _hashlib
            if _hashlib.sha256(raw.encode()).hexdigest() != receipt["raw_sha256"]:
                raw_bad = f"receipt round {receipt['round']}: committed raw sha256 != receipt (tampered)"; break
            try:
                raw_doc = json.loads(raw)
            except Exception as e:
                raw_bad = f"receipt round {receipt['round']}: raw not JSON ({e})"; break
            rverr = _validate(raw_doc, _SCHEMA_ROUND)
            if rverr:
                raw_bad = f"receipt round {receipt['round']}: raw {rverr}"; break
        if raw_bad:
            results[sid] = raw_bad; verified = False; continue
        if int(ledger.get("rounds_used", 0)) > policy["max_rounds"]:
            results[sid] = (f"rounds-exceeded (used {ledger.get('rounds_used')}, PINNED budget "
                            f"{policy['max_rounds']} — widening requires a recorded review-budget "
                            "amendment, never a codex.toml edit; v0.37.5 5.2)"); verified = False; continue
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
    ap.add_argument("--repo", default=".")
    a = ap.parse_args(argv)
    okq, results = gate(a.repo, a.feature_ref, a.slug)
    print(json.dumps({"verdict": "verified" if okq else "hold", "feature_ref": a.feature_ref, "detail": results}))
    return 0 if okq else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
