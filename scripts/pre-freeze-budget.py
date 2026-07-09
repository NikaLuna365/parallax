#!/usr/bin/env python3
"""Fail-closed budget gate for Parallax pre-freeze verifier rounds.

v0.37.3 F3 — independent closure. The state now carries a required `closure` object
(schema: assets/codex/pre-freeze-state.schema.json) that mechanically separates the two
trust levels a live run collapsed into one boolean: `independent-pass` (this script
recorded a round whose own schema-valid verifier verdict was `pass`) versus everything
else (`open` — concerns rounds, a budget cap, a human grant, orchestrator prose). Only
record() writes closure, only a `pass` round flips it, and validate_state_semantics()
re-derives it from the round inventory on every read — so a hand-edited closure (or a
bolted-on `all_resolved: true`) fails the gate instead of certifying a freeze. A human
grant-one authorizes exactly one more verifier round; it never closes anything itself.

v0.38 F3 NEW-MODE (TZ 5.1) — freeze-gate MODE BINDING. A real v0.37.4 production run
invoked `--autonomous --from-doc` froze through the INTERACTIVE human-OK branch with
closure honestly `open` after 3x concerns: the closure state held (never forged), but
nothing bound the gate *selection* to the run's mode. Now:

  * every subcommand requires `--mode {autonomous,interactive}`; the state pins it at init
    (`mode.autonomous`, schema-required) and every later call must match — an autonomous
    run cannot relabel itself interactive at the console (GateError, exit 2);
  * `freeze-check` is the mechanical gate `/parallax:spec` step 10 MUST pass before any
    freeze: interactive -> allow (the explicit human OK remains the gate); autonomous ->
    allow ONLY when closure.status == "independent-pass" — a human present at the console,
    an `on_missing = warn` config, or a missing/never-initialized state file changes
    nothing (fail closed, exit 2, park/escalate; there is deliberately NO interactive
    escape hatch for an autonomous run);
  * `grant-one` refuses outright in autonomous mode (a human round-grant is an interactive
    affordance; autonomous parks instead — TRIAGE gate A2), and validate_state_semantics
    rejects any state where mode.autonomous is true yet grants[] is non-empty, so a
    hand-edited grant fails on the very next read.

v0.38 TZ 5.2 — `pin-policy` writes the freeze-time-frozen review budget snapshot
`.parallax/<slug>/review-policy.frozen.json` (schema
assets/review-policy-frozen.schema.json): the [review] policy actually in force, pinned at
freeze and committed with the contract. epic-gate/triage/merge-ledger evaluate rounds
against the PINNED budget, so a post-freeze `codex.toml` edit can never clear a
rounds-exceeded hold; widening is sanctioned only by a recorded review-budget amendment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError as exc:  # pragma: no cover - Python < 3.11
    raise SystemExit(f"tomllib is required: {exc}")


ROOT = Path(__file__).resolve().parent.parent
STATE_SCHEMA = ROOT / "assets" / "codex" / "pre-freeze-state.schema.json"
ROUND_SCHEMA = ROOT / "assets" / "codex" / "spec-adversary.schema.json"


class GateError(Exception):
    pass


def emit(payload: dict[str, Any], code: int = 0) -> int:
    print(json.dumps(payload, ensure_ascii=True, sort_keys=True))
    return code


def policy_data(path: Path) -> tuple[str, int]:
    try:
        raw = path.read_bytes()
        doc = tomllib.loads(raw.decode("utf-8"))
        review = doc.get("review", {})
        limit = review.get("pre_freeze_max_rounds", review.get("max_rounds", 2))
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
            raise ValueError("[review].pre_freeze_max_rounds must be an integer >= 1")
        return hashlib.sha256(raw).hexdigest(), limit
    except Exception as exc:
        raise GateError(f"cannot read trusted review policy {path}: {exc}") from exc


def validate(doc: dict[str, Any], schema_path: Path) -> None:
    try:
        import jsonschema
    except ImportError as exc:
        raise GateError("jsonschema is required; refusing an unvalidated pre-freeze gate") from exc
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        jsonschema.validate(doc, schema)
    except Exception as exc:
        raise GateError(f"schema validation failed for {schema_path.name}: {exc}") from exc


def read_state(path: Path) -> dict[str, Any]:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise GateError(f"cannot read pre-freeze state {path}: {exc}") from exc
    validate(state, STATE_SCHEMA)
    validate_state_semantics(state)
    validate_state_artifacts(path, state)
    return state


def write_json_atomic(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, ensure_ascii=True, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def validate_state_semantics(state: dict[str, Any]) -> None:
    rounds = state["rounds"]
    grants = state["grants"]
    # v0.38 5.1 — autonomous mode has no human-grant affordance at all: a grant present in
    # an autonomous state (however it got there — hand-edit included) is invalid state,
    # never a usable authorization. Autonomous runs park at the cap; they never self-grant.
    if state["mode"]["autonomous"] and grants:
        raise GateError("autonomous pre-freeze state carries a human grant; autonomous can never "
                        "consume a human round-grant — park to the escalation queue instead")
    if state["rounds_used"] != len(rounds):
        raise GateError("rounds_used does not equal the machine-written round inventory")
    if [item["round"] for item in rounds] != list(range(1, len(rounds) + 1)):
        raise GateError("pre-freeze round inventory is not sequential")
    expected_grants = list(range(state["base_limit"] + 1, state["base_limit"] + len(grants) + 1))
    if [item["round"] for item in grants] != expected_grants:
        raise GateError("human grants are not sequential one-round extensions")
    for grant in grants:
        if grant["token"] != expected_token(state["slug"], grant["round"]):
            raise GateError("human grant token does not match its slug and round")
    if state["rounds_used"] > state["base_limit"] + len(grants):
        raise GateError("state contains an unauthorized pre-freeze round")
    for item in rounds:
        if item["findings_total"] != sum(item["severity_counts"].values()):
            raise GateError(f"round {item['round']} severity counts do not match findings_total")
        if item["artifact"] != f"pre_freeze.round{item['round']}.json":
            raise GateError(f"round {item['round']} points at a non-canonical artifact")
        if item["contract_dir"] != f"pre_freeze.round{item['round']}.contract":
            raise GateError(f"round {item['round']} points at a non-canonical contract snapshot")
    # v0.37.3 F3 — closure must be CONSISTENT with the machine-written round inventory, in
    # both directions. `independent-pass` must name the LAST recorded round, whose verdict
    # must really be `pass`, with a matching artifact + provider — so a hand-crafted
    # closure, or a stale one left over while a later `concerns` round is live, fails the
    # gate instead of certifying it. Conversely, a terminal `pass` round must be reflected
    # as `independent-pass`, so a doctored `open` cannot mask an inconsistent state. An
    # orchestrator/human/self-attested closure needs no branch here: the schema's status
    # enum cannot represent one.
    closure = state["closure"]
    last = rounds[-1] if rounds else None
    if closure["status"] == "independent-pass":
        if last is None or closure["round"] != last["round"]:
            raise GateError("closure claims independent-pass but does not name the last recorded round")
        if last["verdict"] != "pass":
            raise GateError("closure claims independent-pass but the last round's verdict is not pass")
        if closure["artifact"] != last["artifact"]:
            raise GateError("closure artifact does not match the last recorded round")
        if closure["provider"] != last["provider"]:
            raise GateError("closure provider does not match the last recorded round")
    elif last is not None and last["verdict"] == "pass":
        raise GateError("last recorded round is a pass but closure was not machine-written as independent-pass")


def contract_hash(files: list[tuple[str, bytes]]) -> str:
    digest = hashlib.sha256()
    for name, content in sorted(files):
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(len(content)).encode("ascii"))
        digest.update(b"\0")
        digest.update(content)
        digest.update(b"\n")
    return digest.hexdigest()


def contract_files_from_paths(paths: list[Path]) -> list[tuple[str, bytes]]:
    if len(paths) < 3:
        raise GateError("record requires at least spec.md, slices.md, and validation.md contract files")
    names = [path.name for path in paths]
    if len(names) != len(set(names)):
        raise GateError("pre-freeze contract files must have unique basenames")
    try:
        return [(path.name, path.read_bytes()) for path in paths]
    except Exception as exc:
        raise GateError(f"cannot read pre-freeze contract files: {exc}") from exc


def contract_files_from_dir(path: Path) -> list[tuple[str, bytes]]:
    try:
        entries = sorted(item for item in path.iterdir() if item.is_file())
        if not entries:
            raise ValueError("snapshot is empty")
        return [(item.name, item.read_bytes()) for item in entries]
    except Exception as exc:
        raise GateError(f"cannot read contract snapshot {path}: {exc}") from exc


def write_contract_snapshot(path: Path, files: list[tuple[str, bytes]]) -> None:
    if path.exists():
        if contract_hash(contract_files_from_dir(path)) != contract_hash(files):
            raise GateError(f"refusing to overwrite different contract snapshot {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f".{path.name}.", dir=path.parent))
    try:
        for name, content in files:
            (tmp / name).write_bytes(content)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            shutil.rmtree(tmp)


def validate_state_artifacts(state_path: Path, state: dict[str, Any]) -> None:
    for item in state["rounds"]:
        verdict_path = state_path.parent / item["artifact"]
        snapshot_path = state_path.parent / item["contract_dir"]
        try:
            verdict = json.loads(verdict_path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise GateError(f"cannot read recorded verdict {verdict_path}: {exc}") from exc
        validate(verdict, ROUND_SCHEMA)
        counts = {"low": 0, "medium": 0, "high": 0}
        for finding in verdict["findings"]:
            counts[finding["severity"]] += 1
        if verdict["verdict"] != item["verdict"] or counts != item["severity_counts"]:
            raise GateError(f"recorded verdict {verdict_path} does not match pre-freeze state")
        if contract_hash(contract_files_from_dir(snapshot_path)) != item["contract_hash"]:
            raise GateError(f"contract snapshot {snapshot_path} does not match pre-freeze state")


def write_state(path: Path, state: dict[str, Any]) -> None:
    validate(state, STATE_SCHEMA)
    validate_state_semantics(state)
    validate_state_artifacts(path, state)
    write_json_atomic(path, state)


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def expected_token(slug: str, round_number: int) -> str:
    return f"PARALLAX-GRANT:{slug}:pre-freeze-round-{round_number}"


def _mode_autonomous(args: argparse.Namespace) -> bool:
    return args.mode == "autonomous"


def load_or_init(path: Path, policy: Path, slug: str, autonomous: bool) -> dict[str, Any]:
    digest, limit = policy_data(policy)
    if path.exists():
        state = read_state(path)
        if state["slug"] != slug:
            raise GateError(f"state slug {state['slug']!r} does not match {slug!r}")
        # v0.38 5.1 — the mode is pinned at init and every later call must match: an
        # autonomous run cannot relabel itself interactive at the console (or vice versa)
        # to reach the other mode's freeze branch.
        if state["mode"]["autonomous"] != autonomous:
            raise GateError(
                f"pre-freeze state was initialized with mode."
                f"{'autonomous' if state['mode']['autonomous'] else 'interactive'} but this call "
                f"claims --mode {'autonomous' if autonomous else 'interactive'}; the run's mode is "
                "pinned at init and cannot be relabeled mid-run")
        if state["policy_hash"] != digest or state["base_limit"] != limit:
            raise GateError("review policy changed after pre-freeze started; human escalation required")
        return state
    state = {
        "slug": slug,
        "mode": {"autonomous": autonomous},
        "policy_hash": digest,
        "base_limit": limit,
        "rounds_used": 0,
        "grants": [],
        "rounds": [],
        "closure": {"status": "open"},
        "updated_at": now(),
    }
    write_state(path, state)
    return state


def authorized_limit(state: dict[str, Any]) -> int:
    return state["base_limit"] + len(state["grants"])


def decision(state: dict[str, Any]) -> tuple[str, int]:
    next_round = state["rounds_used"] + 1
    if state["rounds_used"] < authorized_limit(state):
        return "run", 0
    return "checkpoint", 2


def check(args: argparse.Namespace) -> int:
    state = load_or_init(args.state, args.policy, args.slug, _mode_autonomous(args))
    action, code = decision(state)
    next_round = state["rounds_used"] + 1
    payload = {
        "decision": action,
        "rounds_used": state["rounds_used"],
        "authorized_limit": authorized_limit(state),
        "next_round": next_round,
        "closure": state["closure"]["status"],
    }
    if action == "checkpoint":
        payload["grant_token"] = expected_token(state["slug"], next_round)
        payload["reason"] = "pre-freeze round budget exhausted; explicit human grant required"
    return emit(payload, code)


def record(args: argparse.Namespace) -> int:
    state = load_or_init(args.state, args.policy, args.slug, _mode_autonomous(args))
    action, _ = decision(state)
    if action != "run":
        raise GateError("pre-freeze round was not authorized; checkpoint before invoking verifier")

    try:
        verdict = json.loads(args.verdict.read_text(encoding="utf-8"))
    except Exception as exc:
        raise GateError(f"cannot read verifier verdict {args.verdict}: {exc}") from exc
    validate(verdict, ROUND_SCHEMA)

    round_number = state["rounds_used"] + 1
    canonical = args.state.parent / f"pre_freeze.round{round_number}.json"
    snapshot = args.state.parent / f"pre_freeze.round{round_number}.contract"
    candidate_files = contract_files_from_paths(args.contract_file)
    if canonical.exists():
        try:
            existing = json.loads(canonical.read_text(encoding="utf-8"))
        except Exception as exc:
            raise GateError(f"cannot recover existing round artifact {canonical}: {exc}") from exc
        if existing != verdict:
            raise GateError(f"refusing to overwrite different round artifact {canonical}")
    else:
        write_json_atomic(canonical, verdict)
    write_contract_snapshot(snapshot, candidate_files)

    counts = {"low": 0, "medium": 0, "high": 0}
    for finding in verdict["findings"]:
        counts[finding["severity"]] += 1
    state["rounds_used"] = round_number
    state["rounds"].append(
        {
            "round": round_number,
            "provider": args.provider,
            "verdict": verdict["verdict"],
            "findings_total": len(verdict["findings"]),
            "severity_counts": counts,
            "artifact": canonical.name,
            "contract_dir": snapshot.name,
            "contract_hash": contract_hash(candidate_files),
            "recorded_at": now(),
        }
    )
    # v0.37.3 F3 — the ONLY closure writer. `independent-pass` is derived exclusively from
    # this round's own schema-valid verifier verdict; a `concerns` round (including the one
    # that exhausts the budget) leaves closure `open`. Nothing else — no flag, no free-text
    # note, no human grant — can produce a closed state, and validate_state_semantics()
    # re-derives this from the round inventory on every subsequent read.
    if verdict["verdict"] == "pass":
        state["closure"] = {
            "status": "independent-pass",
            "round": round_number,
            "artifact": canonical.name,
            "provider": args.provider,
            "closed_at": now(),
            "closed_by": "independent-verifier",
        }
    else:
        state["closure"] = {"status": "open"}
    state["updated_at"] = now()
    write_state(args.state, state)

    if verdict["verdict"] == "pass":
        return emit({"decision": "pass", "round": round_number, "artifact": canonical.name,
                     "closure": "independent-pass"})
    next_action, code = decision(state)
    payload = {
        "decision": "revise" if next_action == "run" else "checkpoint",
        "round": round_number,
        "findings_total": len(verdict["findings"]),
        "severity_counts": counts,
        "artifact": canonical.name,
    }
    if next_action == "checkpoint":
        next_round = round_number + 1
        payload["grant_token"] = expected_token(state["slug"], next_round)
        payload["reason"] = "pre-freeze round budget exhausted; explicit human grant required"
    return emit(payload, code)


def grant_one(args: argparse.Namespace) -> int:
    # v0.38 5.1 / TRIAGE A2 — a human round-grant is an INTERACTIVE affordance. In autonomous
    # mode there is no human at the gate by definition, so grant-one refuses outright before
    # touching state: an autonomous run parks at the cap (escalation queue), it never
    # self-grants a "human" round. Checked from the CLI flag AND from the pinned state mode
    # (load_or_init cross-checks them), so neither side can be spoofed alone.
    if _mode_autonomous(args):
        raise GateError("grant-one is an interactive affordance; an autonomous run can never "
                        "consume a human round-grant — park to the escalation queue instead")
    state = load_or_init(args.state, args.policy, args.slug, _mode_autonomous(args))
    if state["rounds_used"] < authorized_limit(state):
        raise GateError("an authorized pre-freeze round is still unused; cannot pre-authorize another")
    next_round = state["rounds_used"] + 1
    token = expected_token(state["slug"], next_round)
    if args.token != token:
        raise GateError(f"invalid human grant token; expected {token}")
    state["grants"].append(
        {
            "round": next_round,
            "token": token,
            "approved_by": "human",
            "approved_at": now(),
        }
    )
    state["updated_at"] = now()
    write_state(args.state, state)
    return emit({"decision": "granted", "round": next_round, "authorized_limit": authorized_limit(state)})


def freeze_check(args: argparse.Namespace) -> int:
    """v0.38 5.1 / gate A1 — the mechanical freeze gate. /parallax:spec step 10 MUST run this
    (and see exit 0) before freezing, in EITHER mode. The decision is derived from artifacts
    only — a human at the console is not an input:

      interactive -> allow (path interactive-human-ok; the explicit human OK remains the gate
                     the orchestrator must still collect — this check only proves the run is
                     genuinely entitled to that branch).
      autonomous  -> allow ONLY when the pinned state exists and closure.status ==
                     "independent-pass" (path autonomous-independent-pass). A missing state
                     (verifier never ran / on_missing=warn) or an open/concerns closure is a
                     hard refuse (exit 2): park to the escalation queue. There is NO
                     interactive escape hatch for an autonomous run.
    """
    autonomous = _mode_autonomous(args)
    if not args.state.exists():
        if autonomous:
            return emit({"decision": "refuse",
                         "reason": "autonomous freeze requires closure.status=independent-pass, "
                                   "but no pre-freeze state exists (the independent verifier never "
                                   "ran) — park to the escalation queue; on_missing=warn does not "
                                   "license an autonomous freeze (v0.38 5.1)"}, 2)
        return emit({"decision": "allow", "freeze_path": "interactive-human-ok",
                     "note": "no pre-freeze verifier state; the explicit human OK is the gate"})
    state = load_or_init(args.state, args.policy, args.slug, autonomous)
    closure = state["closure"]["status"]
    if autonomous:
        if closure == "independent-pass":
            return emit({"decision": "allow", "freeze_path": "autonomous-independent-pass",
                         "closure": closure, "rounds_used": state["rounds_used"]})
        return emit({"decision": "refuse", "closure": closure,
                     "rounds_used": state["rounds_used"],
                     "reason": "mode.autonomous=true and closure.status != independent-pass — the "
                               "interactive human-OK branch is unreachable in autonomous mode; a "
                               "human at the console does not change this. Park to the escalation "
                               "queue (v0.38 5.1, closes the RUN1 interactive-freeze side door)"}, 2)
    return emit({"decision": "allow", "freeze_path": "interactive-human-ok", "closure": closure,
                 "note": "interactive mode: collect the explicit human OK; this check only binds "
                         "the branch to the run's real mode"})


_FROZEN_POLICY_SCHEMA = ROOT / "assets" / "review-policy-frozen.schema.json"
_TRIAGE_POLICY_KEYS = ("max_rounds", "block_severities", "advisory_severities", "always_block_kinds")


def _triage_policy_hash(policy: dict[str, Any]) -> str:
    """Identical canonicalization to scripts/triage.py policy_hash() — duplicated here (14 lines
    vs an import of a dash-named module) and LOCKED to it by the harness, which computes both
    and asserts equality."""
    canon = {k: (sorted(policy[k]) if isinstance(policy.get(k), list) else policy.get(k))
             for k in _TRIAGE_POLICY_KEYS}
    return hashlib.sha256(json.dumps(canon, sort_keys=True).encode()).hexdigest()[:16]


def pin_policy(args: argparse.Namespace) -> int:
    """v0.38 5.2 / gate A3 — pin the [review] budget in force at FREEZE into a frozen,
    committed snapshot. epic-gate/triage/merge-ledger evaluate rounds against THIS, never the
    live codex.toml, so a post-freeze `sed` of max_rounds can no longer clear a hold; widening
    is sanctioned only by a recorded review-budget amendment (contract-amend.py)."""
    try:
        raw = args.policy.read_bytes()
        doc = tomllib.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise GateError(f"cannot read trusted review policy {args.policy}: {exc}") from exc
    review = doc.get("review", {})
    policy = {
        "max_rounds": review.get("max_rounds", 2),
        "block_severities": review.get("block_severities", ["medium", "high"]),
        "advisory_severities": review.get("advisory_severities", ["low"]),
        "always_block_kinds": review.get("always_block_kinds", ["safety", "anti-cheat", "spec-gap"]),
    }
    if isinstance(policy["max_rounds"], bool) or not isinstance(policy["max_rounds"], int) \
            or policy["max_rounds"] < 1:
        raise GateError("[review].max_rounds must be an integer >= 1")
    pre_freeze_limit = review.get("pre_freeze_max_rounds", policy["max_rounds"])
    snapshot = {
        "schema_version": "parallax-review-policy-frozen-v1",
        "slug": args.slug,
        "pinned_at": now(),
        "source_policy_sha256": hashlib.sha256(raw).hexdigest(),
        "policy": policy,
        "pre_freeze_max_rounds": pre_freeze_limit,
        "policy_hash": _triage_policy_hash(policy),
    }
    validate(snapshot, _FROZEN_POLICY_SCHEMA)
    out = args.out or (args.policy.parent / "review-policy.frozen.json")
    if out.exists():
        existing = json.loads(out.read_text(encoding="utf-8"))
        stable = {k: existing.get(k) for k in ("slug", "policy", "policy_hash", "pre_freeze_max_rounds")}
        wanted = {k: snapshot.get(k) for k in ("slug", "policy", "policy_hash", "pre_freeze_max_rounds")}
        if stable != wanted:
            raise GateError(f"refusing to overwrite a DIFFERENT pinned policy at {out} — the frozen "
                            "budget is immutable; widen it only via a recorded review-budget amendment")
        return emit({"decision": "pinned", "out": str(out), "policy_hash": snapshot["policy_hash"],
                     "note": "identical snapshot already pinned"})
    write_json_atomic(out, snapshot)
    return emit({"decision": "pinned", "out": str(out), "policy_hash": snapshot["policy_hash"],
                 "max_rounds": policy["max_rounds"]})


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("state", type=Path)
    common.add_argument("--policy", type=Path, required=True)
    common.add_argument("--slug", required=True)
    common.add_argument("--mode", required=True, choices=["autonomous", "interactive"],
                        help="v0.38 5.1: the run's invocation mode. Pinned into the state at init; "
                             "every later call must match — a mode relabel is a GateError.")

    root = argparse.ArgumentParser(description=__doc__)
    subs = root.add_subparsers(dest="command", required=True)
    p_check = subs.add_parser("check", parents=[common])
    p_check.set_defaults(func=check)
    p_record = subs.add_parser("record", parents=[common])
    p_record.add_argument("verdict", type=Path)
    p_record.add_argument("--provider", required=True)
    p_record.add_argument("--contract-file", action="append", type=Path, required=True)
    p_record.set_defaults(func=record)
    p_grant = subs.add_parser("grant-one", parents=[common])
    p_grant.add_argument("--token", required=True)
    p_grant.set_defaults(func=grant_one)
    p_freeze = subs.add_parser("freeze-check", parents=[common],
                               help="v0.38 5.1: mechanical freeze gate — run before ANY freeze")
    p_freeze.set_defaults(func=freeze_check)
    p_pin = subs.add_parser("pin-policy",
                            help="v0.38 5.2: pin the [review] budget in force at freeze")
    p_pin.add_argument("--policy", type=Path, required=True)
    p_pin.add_argument("--slug", required=True)
    p_pin.add_argument("--out", type=Path, default=None,
                       help="output path (default: review-policy.frozen.json next to the policy)")
    p_pin.set_defaults(func=pin_policy)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except GateError as exc:
        return emit({"decision": "escalate", "error": str(exc)}, 2)


if __name__ == "__main__":
    raise SystemExit(main())
