#!/usr/bin/env python3
"""Parallax pinned review-budget authority (v0.38 5.2, gates A3/A5) — shared module.

The v0.37.4 live audit caught a mechanical gate being cleared by editing the policy it
checks: an epic-gate HOLD on `rounds_used=3 > max_rounds=2` was resolved by sed-editing
`codex.toml max_rounds 2->3` post-hoc and re-stamping all five ledgers. The disposition
was substantively correct, but the mechanism could not distinguish "budget widened for
real safety work" from "budget retro-fitted to launder a breach".

From v0.38 the budget authority is three-layered and fail-closed:

  1. PINNED AT FREEZE — `.parallax/<slug>/review-policy.frozen.json` (written by
     `pre-freeze-budget.py pin-policy`, schema assets/review-policy-frozen.schema.json)
     records the [review] policy in force plus its triage-canonical `policy_hash`.
  2. WIDENED ONLY BY A RECORDED AMENDMENT — `.parallax/<slug>/amendments/BA-*.json`
     (schema assets/review-budget-amendment.schema.json, written by
     `contract-amend.py record-budget`): a human-approved, machine-tokened, prev->new
     policy_hash chain starting from the pinned hash. A `codex.toml` edit is NOT a link
     in this chain and therefore changes no gate verdict.
  3. ENFORCED AT EVERY CONSUMER — `merge-ledger.py` refuses a round beyond the effective
     budget (A5), `triage.py --pinned-policy` disposes under the pinned policy, and
     `epic-gate.py` re-derives the effective policy from the COMMITTED snapshot+chain and
     additionally requires the committed codex.toml to hash-match it (live/pinned
     mismatch => HOLD).

This module is deliberately import-friendly (underscore name); the CLI surfaces live in
scripts/contract-amend.py (record-budget / verify-budget) and the gates above.
"""
from __future__ import annotations

import hashlib
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
FROZEN_SCHEMA = os.path.join(_HERE, "..", "assets", "review-policy-frozen.schema.json")
AMEND_SCHEMA = os.path.join(_HERE, "..", "assets", "review-budget-amendment.schema.json")
_POLICY_KEYS = ("max_rounds", "block_severities", "advisory_severities", "always_block_kinds")


class BudgetError(Exception):
    """Fail-closed: any inconsistency in the pinned snapshot or the amendment chain."""


def policy_hash(policy: dict) -> str:
    """MUST stay byte-identical to scripts/triage.py policy_hash() (the harness locks the two
    implementations together by computing both over the same policy)."""
    canon = {k: (sorted(policy[k]) if isinstance(policy.get(k), list) else policy.get(k))
             for k in _POLICY_KEYS}
    return hashlib.sha256(json.dumps(canon, sort_keys=True).encode()).hexdigest()[:16]


def _validate(doc: dict, schema_path: str) -> None:
    try:
        import jsonschema
    except ImportError as exc:
        raise BudgetError(f"jsonschema is required; refusing an unvalidated budget artifact: {exc}")
    try:
        jsonschema.validate(doc, json.load(open(schema_path)))
    except Exception as exc:
        raise BudgetError(f"schema-invalid against {os.path.basename(schema_path)}: "
                          f"{getattr(exc, 'message', exc)}")


def load_frozen(doc: dict, slug: str) -> dict:
    """Validate a pinned snapshot: schema, slug identity, and SELF-CONSISTENT policy_hash
    (recomputed — a hand-edited snapshot whose hash doesn't match its own policy fails)."""
    _validate(doc, FROZEN_SCHEMA)
    if doc["slug"] != slug:
        raise BudgetError(f"pinned policy slug {doc['slug']!r} != {slug!r}")
    if policy_hash(doc["policy"]) != doc["policy_hash"]:
        raise BudgetError("pinned policy_hash does not match its own policy (snapshot tampered)")
    return doc


def expected_token(slug: str, amendment_id: str, prev_hash: str, new_hash: str) -> str:
    """The machine-minted grant token a human must repeat to authorize a budget widening —
    fully derivable from the amendment's own content, so a forged token is detectable."""
    return f"PARALLAX-BUDGET-GRANT:{slug}:{amendment_id}:{prev_hash}:{new_hash}"


def amendment_ok(rec: dict, slug: str) -> None:
    """Structural + authority validity of ONE budget amendment (fail-closed)."""
    _validate(rec, AMEND_SCHEMA)
    if rec["slug"] != slug:
        raise BudgetError(f"budget amendment slug {rec['slug']!r} != {slug!r}")
    if policy_hash(rec["new_policy"]) != rec["new_policy_hash"]:
        raise BudgetError(f"budget amendment {rec['amendment_id']}: new_policy_hash does not match "
                          "its own new_policy (record tampered)")
    if rec["prev_policy_hash"] == rec["new_policy_hash"]:
        raise BudgetError(f"budget amendment {rec['amendment_id']}: prev == new (no-op amendment)")
    want = expected_token(slug, rec["amendment_id"], rec["prev_policy_hash"], rec["new_policy_hash"])
    if rec["grant_token"] != want:
        raise BudgetError(f"budget amendment {rec['amendment_id']}: grant_token does not match the "
                          "machine-minted token for its own content")


def budget_records(records: list[dict]) -> list[dict]:
    """Filter a mixed amendments/ directory: budget amendments only (contract tightenings —
    parallax-contract-amendment-v1 — belong to the contract chain and are ignored here)."""
    return [r for r in records
            if r.get("schema_version") == "parallax-review-budget-amendment-v1"
            or r.get("kind") == "review-budget-amendment"]


def effective_policy(frozen: dict, records: list[dict], slug: str) -> tuple[dict, str, list[str]]:
    """Walk the budget-amendment chain from the PINNED policy_hash. Returns
    (effective_policy, effective_policy_hash, chain_ids). Fail-closed on any invalid record,
    a fork (two amendments from one hash), or a cycle. An empty chain returns the pinned
    policy itself — which is the normal case."""
    load_frozen(frozen, slug)
    by_prev: dict[str, dict] = {}
    for rec in budget_records(records):
        amendment_ok(rec, slug)
        prev = rec["prev_policy_hash"]
        if prev in by_prev:
            raise BudgetError(f"ambiguous budget chain: two amendments widen from {prev}")
        by_prev[prev] = rec
    policy = dict(frozen["policy"])
    cur = frozen["policy_hash"]
    chain: list[str] = []
    seen = set()
    while cur in by_prev:
        if cur in seen:
            raise BudgetError("budget amendment chain cycle")
        seen.add(cur)
        rec = by_prev[cur]
        policy = dict(rec["new_policy"])
        chain.append(rec["amendment_id"])
        cur = rec["new_policy_hash"]
    return policy, cur, chain


def load_amendment_files(amendments_dir: str) -> list[dict]:
    """Working-tree loader (committed-ref loading stays with the gate that owns git access)."""
    records = []
    if not os.path.isdir(amendments_dir):
        return records
    for name in sorted(os.listdir(amendments_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(amendments_dir, name)
        try:
            records.append(json.load(open(path)))
        except Exception as exc:
            raise BudgetError(f"unreadable amendment {name}: {exc}")
    return records
