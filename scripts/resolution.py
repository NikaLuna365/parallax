#!/usr/bin/env python3
"""Parallax safe-completion — the ONLY writer of the resolution queue lifecycle, batch receipts, and
contract-generation transitions in feature-state.json (DESIGN_v0.31_safe_completion.md §16).

A parked spec-gap is turned into a *safely completed* feature by an explicit, one-time human decision that
mints a NEW contract generation and fully invalidates the old certification — never by reusing old
code/tests/ledgers. Prompt contracts (commands/*.md) MUST NOT hand-edit these JSON files; they call this
script, which is fail-closed: jsonschema missing, schema-invalid input, a stale contract hash, a reused or
mismatched confirmation token, an empty contract diff, an unclosed blocking item, an unsupported parked
reason, or a non-+1 generation each => exit 2 (escalate), never a silent success.

Subcommands:
  init-feature  STATE  --slug --feature-id --run-id --base-oid --tip-oid --contract-hash
  migrate       STATE  --slug --run-state RS [--feature-id UUID] --base-oid --tip-oid --contract-hash  # v0.30 -> v0.31, idempotent
  add-item      QUEUE  --slug --item-file ITEM.json            # append a structured resolution item (identity-immutable)
  set-item      QUEUE  --id R-... --to resolved|superseded
  mint-token           --slug --from-gen N --batch-id RB-... --old-hash H --new-hash H
  apply         STATE  --queue Q --resolutions-dir D --slug --batch-id --source-run-id --new-run-id
                       --old-hash --new-hash --token T --human-text TXT --decisions DECISIONS.json
  abandon       STATE  --slug --human-text TXT
  status        STATE  --queue Q
Exit: 0 ok, 2 escalate/fail-closed, 3 bad input. Prints a JSON result to stdout.
"""
import argparse, hashlib, json, os, sys, tempfile, uuid
from datetime import datetime, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
_S_FEATURE = os.path.join(_HERE, "..", "assets", "feature-state.schema.json")
_S_QUEUE   = os.path.join(_HERE, "..", "assets", "resolution-queue.schema.json")
_S_RECEIPT = os.path.join(_HERE, "..", "assets", "resolution-receipt.schema.json")
_NEW_GEN_DECISIONS = {"choose-option", "custom-rule", "rescope"}


class Escalate(Exception):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _emit(payload, code=0):
    print(json.dumps(payload, ensure_ascii=True, sort_keys=True))
    return code


def _validate(doc, schema_path):
    """Fail-closed: raise Escalate if jsonschema is unavailable, the schema is missing, or doc is invalid."""
    try:
        import jsonschema
    except ImportError as e:
        raise Escalate(f"jsonschema not importable; refusing an unvalidated resolution write ({e})")
    if not os.path.exists(schema_path):
        raise Escalate(f"schema missing: {schema_path}")
    try:
        jsonschema.validate(doc, json.load(open(schema_path)))
    except Exception as e:
        raise Escalate(f"schema validation failed for {os.path.basename(schema_path)}: {getattr(e, 'message', e)}")


def _read_json(path):
    try:
        return json.loads(open(path, encoding="utf-8").read())
    except Exception as e:
        raise Escalate(f"cannot read {path}: {e}")


def _write_atomic(path, doc):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as h:
            json.dump(doc, h, ensure_ascii=True, indent=2, sort_keys=True); h.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def expected_token(slug, from_gen, batch_id, old_hash, new_hash):
    return f"PARALLAX-RESOLVE:{slug}:g{from_gen}->g{from_gen + 1}:{batch_id}:{old_hash[:12]}:{new_hash[:12]}"


# ---- queue helpers ----------------------------------------------------------
def _load_queue(path, slug):
    if os.path.exists(path):
        q = _read_json(path); _validate(q, _S_QUEUE)
        if q["slug"] != slug:
            raise Escalate(f"queue slug {q['slug']!r} != {slug!r}")
        return q
    return {"schema_version": 1, "slug": slug, "items": []}


def add_item(a):
    q = _load_queue(a.queue, a.slug)
    item = _read_json(a.item_file)
    if any(it["id"] == item.get("id") for it in q["items"]):
        raise Escalate(f"resolution item {item.get('id')!r} already exists; the queue is append-only by identity")
    q["items"].append(item)
    _validate(q, _S_QUEUE)                                   # rejects bad kind / missing source hash / spec refs
    _write_atomic(a.queue, q)
    return _emit({"decision": "added", "id": item["id"], "open_items": sum(1 for it in q["items"] if it["status"] == "open")})


def set_item(a):
    q = _load_queue(a.queue, a.slug)
    found = next((it for it in q["items"] if it["id"] == a.id), None)
    if not found:
        raise Escalate(f"no such item {a.id!r}")
    if found["status"] != "open":
        raise Escalate(f"item {a.id!r} is {found['status']!r}; only open items transition")
    if a.to not in ("resolved", "superseded"):
        raise Escalate("item may only move open -> resolved|superseded")
    found["status"] = a.to
    _validate(q, _S_QUEUE); _write_atomic(a.queue, q)
    return _emit({"decision": "set", "id": a.id, "status": a.to})


# ---- feature-state helpers --------------------------------------------------
def init_feature(a):
    if os.path.exists(a.state):
        raise Escalate(f"feature-state already exists at {a.state}")
    st = {
        "schema_version": 1, "feature_id": a.feature_id, "slug": a.slug, "generation": 1,
        "active_run_id": a.run_id, "parent_run_id": None, "generation_base_oid": a.base_oid,
        "feature_tip_before_generation": a.tip_oid, "contract_hash": a.contract_hash,
        "status": "running", "resolution_chain": [],
    }
    _validate(st, _S_FEATURE); _write_atomic(a.state, st)
    return _emit({"decision": "initialized", "generation": 1, "feature_id": a.feature_id})


def _load_state(path, slug):
    st = _read_json(path); _validate(st, _S_FEATURE)
    if st["slug"] != slug:
        raise Escalate(f"feature-state slug {st['slug']!r} != {slug!r}")
    if len(st["resolution_chain"]) != st["generation"] - 1:
        raise Escalate("feature-state resolution_chain length != generation-1")
    return st


def mint_token(a):
    return _emit({"token": expected_token(a.slug, a.from_gen, a.batch_id, a.old_hash, a.new_hash)})


_TRANSITIONS = {("running", "needs-resolution"), ("needs-resolution", "resolving"),
                ("resolving", "needs-resolution")}  # resolving->running is done atomically by apply


def transition(a):
    st = _load_state(a.state, a.slug)
    if (st["status"], a.to) not in _TRANSITIONS:
        raise Escalate(f"illegal status transition {st['status']!r} -> {a.to!r}")
    st["status"] = a.to
    _validate(st, _S_FEATURE); _write_atomic(a.state, st)
    return _emit({"decision": "transitioned", "status": a.to})


def abandon(a):
    st = _load_state(a.state, a.slug)
    if st["status"] not in ("needs-resolution", "resolving"):
        raise Escalate(f"abandon requires status needs-resolution|resolving, not {st['status']!r}")
    st["status"] = "abandoned"
    _validate(st, _S_FEATURE); _write_atomic(a.state, st)
    return _emit({"decision": "abandoned", "slug": a.slug, "exact_human_text": a.human_text})


def apply(a):
    st = _load_state(a.state, a.slug)
    if st["status"] not in ("needs-resolution", "resolving"):
        raise Escalate(f"apply requires status needs-resolution|resolving, not {st['status']!r}")
    # (1) stale source contract hash
    if st["contract_hash"] != a.old_hash:
        raise Escalate(f"stale source contract hash: feature-state {st['contract_hash'][:12]} != --old-hash {a.old_hash[:12]}")
    # (2) empty contract diff
    if a.new_hash == a.old_hash:
        raise Escalate("empty contract diff: new_contract_hash == source_contract_hash")
    # (3) exact, single-use confirmation token
    want = expected_token(a.slug, st["generation"], a.batch_id, a.old_hash, a.new_hash)
    if a.token != want:
        raise Escalate(f"confirmation token mismatch; expected {want}")
    if a.batch_id in st["resolution_chain"]:
        raise Escalate(f"batch {a.batch_id} already applied (token is single-use)")
    receipt_path = os.path.join(a.resolutions_dir, f"{a.batch_id}.json")
    if os.path.exists(receipt_path):
        raise Escalate(f"receipt {receipt_path} already exists; token is single-use")
    # (4) every OPEN blocking item of THIS generation has a concrete decision
    decisions = _read_json(a.decisions)
    if not isinstance(decisions, list) or not decisions:
        raise Escalate("decisions must be a non-empty list of {item_id, decision, ...}")
    open_ids = {it["id"] for it in _load_queue(a.queue, a.slug)["items"]
                if it["status"] == "open" and it["source_contract_hash"] == a.old_hash}
    decided_ids = {d.get("item_id") for d in decisions}
    if any(d.get("decision") not in _NEW_GEN_DECISIONS for d in decisions):
        raise Escalate("a new generation admits only choose-option|custom-rule|rescope (no ignore/ship-anyway/manual-fixed; use 'abandon' to drop the feature)")
    if open_ids != decided_ids:
        raise Escalate(f"unclosed blocking items: open={sorted(open_ids)} decided={sorted(decided_ids)}")
    # build + validate + write the receipt
    receipt = {
        "schema_version": 1, "batch_id": a.batch_id, "slug": a.slug,
        "from_generation": st["generation"], "to_generation": st["generation"] + 1,
        "source_run_id": a.source_run_id, "new_run_id": a.new_run_id,
        "source_contract_hash": a.old_hash, "new_contract_hash": a.new_hash,
        "item_decisions": decisions, "exact_human_text": a.human_text,
        "confirmation_token": a.token,
        "contract_diff_hash": hashlib.sha256(f"{a.old_hash}->{a.new_hash}".encode()).hexdigest(),
        "invalidation_scope": "all-slices", "created_at": _now(), "status": "applied",
    }
    _validate(receipt, _S_RECEIPT)
    _write_atomic(receipt_path, receipt)
    # transition the queue items -> resolved
    q = _load_queue(a.queue, a.slug)
    for it in q["items"]:
        if it["id"] in decided_ids and it["status"] == "open":
            it["status"] = "resolved"
    _validate(q, _S_QUEUE); _write_atomic(a.queue, q)
    # advance feature-state to the new generation
    st.update({
        "generation": st["generation"] + 1, "parent_run_id": st["active_run_id"],
        "active_run_id": a.new_run_id, "contract_hash": a.new_hash, "status": "running",
        "resolution_chain": st["resolution_chain"] + [a.batch_id],
    })
    _validate(st, _S_FEATURE); _write_atomic(a.state, st)
    return _emit({"decision": "applied", "batch_id": a.batch_id, "from_generation": receipt["from_generation"],
                  "to_generation": receipt["to_generation"], "new_run_id": a.new_run_id})


def status(a):
    st = _load_state(a.state, a.slug) if os.path.exists(a.state) else None
    q = _load_queue(a.queue, a.slug) if a.queue and os.path.exists(a.queue) else {"items": []}
    openi = [it["id"] for it in q["items"] if it["status"] == "open"]
    return _emit({"slug": a.slug, "generation": st["generation"] if st else None,
                  "status": st["status"] if st else None, "open_items": openi})


def migrate(a):
    """v0.30 -> v0.31: synthesize a generation-1 feature-state from an existing run-state, assign a feature_id,
    and stamp the run-state's feature_id/contract_generation. Idempotent — if a feature-state already exists for
    this slug it is a validated no-op. Fail-closed — a missing or structurally-insufficient run-state escalates
    (a free-text escalations.md is NOT an authoritative source; start a fresh /parallax:spec instead of guessing)."""
    if os.path.exists(a.state):
        st = _load_state(a.state, a.slug)                       # validates schema + slug + chain==gen-1
        return _emit({"decision": "already-migrated", "generation": st["generation"],
                      "feature_id": st["feature_id"], "status": st["status"]})
    if not os.path.exists(a.run_state):
        raise Escalate(f"no run-state at {a.run_state}: nothing structured to migrate; start a fresh /parallax:spec "
                       f"(a free-text escalations.md is not an authoritative source)")
    rs = _read_json(a.run_state)
    for k in ("slug", "run_id", "status"):
        if not rs.get(k):
            raise Escalate(f"run-state missing {k!r}: insufficient structured source to migrate; start a fresh /parallax:spec")
    if rs["slug"] != a.slug:
        raise Escalate(f"run-state slug {rs['slug']!r} != {a.slug!r}")
    feature_id = a.feature_id or str(uuid.uuid4())
    status_v = "complete" if rs["status"] == "complete" else "running"   # v0.30 statuses map onto the feature lifecycle
    st = {
        "schema_version": 1, "feature_id": feature_id, "slug": a.slug, "generation": 1,
        "active_run_id": rs["run_id"], "parent_run_id": None, "generation_base_oid": a.base_oid,
        "feature_tip_before_generation": a.tip_oid, "contract_hash": a.contract_hash,
        "status": status_v, "resolution_chain": [],
    }
    _validate(st, _S_FEATURE); _write_atomic(a.state, st)
    # Stamp the run-state so the gate sees a consistent identity (both fields are optional in v0.30 -> gen 1).
    changed = False
    if not rs.get("feature_id"):
        rs["feature_id"] = feature_id; changed = True
    if rs.get("contract_generation") is None:
        rs["contract_generation"] = 1; changed = True
    if changed:
        _write_atomic(a.run_state, rs)
    return _emit({"decision": "migrated", "generation": 1, "feature_id": feature_id, "status": status_v})


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("init-feature"); g.add_argument("state"); g.add_argument("--slug", required=True)
    g.add_argument("--feature-id", required=True); g.add_argument("--run-id", required=True)
    g.add_argument("--base-oid", required=True); g.add_argument("--tip-oid", required=True)
    g.add_argument("--contract-hash", required=True); g.set_defaults(func=init_feature)
    ai = sub.add_parser("add-item"); ai.add_argument("queue"); ai.add_argument("--slug", required=True)
    ai.add_argument("--item-file", required=True); ai.set_defaults(func=add_item)
    si = sub.add_parser("set-item"); si.add_argument("queue"); si.add_argument("--slug", required=True)
    si.add_argument("--id", required=True); si.add_argument("--to", required=True); si.set_defaults(func=set_item)
    mt = sub.add_parser("mint-token"); mt.add_argument("--slug", required=True); mt.add_argument("--from-gen", type=int, required=True)
    mt.add_argument("--batch-id", required=True); mt.add_argument("--old-hash", required=True); mt.add_argument("--new-hash", required=True); mt.set_defaults(func=mint_token)
    ap = sub.add_parser("apply"); ap.add_argument("state"); ap.add_argument("--queue", required=True)
    ap.add_argument("--resolutions-dir", required=True); ap.add_argument("--slug", required=True)
    ap.add_argument("--batch-id", required=True); ap.add_argument("--source-run-id", required=True)
    ap.add_argument("--new-run-id", required=True); ap.add_argument("--old-hash", required=True)
    ap.add_argument("--new-hash", required=True); ap.add_argument("--token", required=True)
    ap.add_argument("--human-text", required=True); ap.add_argument("--decisions", required=True); ap.set_defaults(func=apply)
    tr = sub.add_parser("transition"); tr.add_argument("state"); tr.add_argument("--slug", required=True); tr.add_argument("--to", required=True); tr.set_defaults(func=transition)
    ab = sub.add_parser("abandon"); ab.add_argument("state"); ab.add_argument("--slug", required=True); ab.add_argument("--human-text", required=True); ab.set_defaults(func=abandon)
    stt = sub.add_parser("status"); stt.add_argument("state"); stt.add_argument("--slug", required=True); stt.add_argument("--queue"); stt.set_defaults(func=status)
    mg = sub.add_parser("migrate"); mg.add_argument("state"); mg.add_argument("--slug", required=True)
    mg.add_argument("--run-state", required=True); mg.add_argument("--feature-id")
    mg.add_argument("--base-oid", required=True); mg.add_argument("--tip-oid", required=True)
    mg.add_argument("--contract-hash", required=True); mg.set_defaults(func=migrate)
    return p


def main(argv):
    a = build_parser().parse_args(argv)
    try:
        return a.func(a)
    except Escalate as e:
        return _emit({"decision": "escalate", "error": str(e)}, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
