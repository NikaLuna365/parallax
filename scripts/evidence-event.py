#!/usr/bin/env python3
"""Parallax evidence-event helper (v0.37.3 F5) — the deterministic writer for run-phase
live-run evidence.

The v0.36 auditability contract promises an append-only, schema-valid event timeline at
.parallax/<slug>/evidence/events.jsonl — but three post-v0.37.2 production runs showed the
timeline stopping at `spec_frozen`: Phase 2-5 (slice dispatch, arbiter iterations, codex
rounds, greens, PRs, merges) left no structured trace, and run-evidence.json sat frozen at
status "frozen-spec". Prose wiring alone did not survive contact with a real run, so this
helper makes the write itself deterministic; /parallax:run's slice loop calls it at each
transition instead of hand-assembling JSON.

Subcommands:
  append      append ONE schema-valid event line to <evidence-dir>/events.jsonl.
              - validates the event against assets/run-evidence-event.schema.json BEFORE
                writing (fail closed: an invalid event writes nothing, exit 2);
              - creates parent directories when missing;
              - append-only by construction: opens "a", never rewrites or truncates;
              - if <evidence-dir>/run-evidence.json exists, its run.run_id/slug must match
                the event's (exit 2 on mismatch) — an event cannot be filed under another
                run's ledger.
  update-run  update <evidence-dir>/run-evidence.json in place (status and/or repo fields),
              refresh run.updated_at, and re-validate the WHOLE document against
              assets/run-evidence.schema.json before atomically replacing it. Only updates
              an existing file (creation stays with Phase 1's documented wiring). This is
              how run.status legitimately moves frozen-spec -> running -> complete instead
              of sticking at frozen-spec.

This is an auditability mechanism, not a benchmark: events are structured observations of
what the run did. Missing data stays null/absent — never invented (v0.36 contract).

Exit: 0 ok; 2 invalid input / mismatch (fail closed — nothing written); 3 bad environment
(missing jsonschema, unreadable schema/target).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVENT_SCHEMA = ROOT / "assets" / "run-evidence-event.schema.json"
RUN_SCHEMA = ROOT / "assets" / "run-evidence.schema.json"


def _fail(msg: str, code: int) -> int:
    print(json.dumps({"error": msg}))
    return code


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _validate(doc, schema_path: Path):
    try:
        import jsonschema
    except ImportError as exc:
        raise EnvironmentError(f"jsonschema is required; refusing an unvalidated evidence write: {exc}")
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    jsonschema.validate(doc, schema)


def _load_run_evidence(evidence_dir: Path):
    path = evidence_dir / "run-evidence.json"
    if not path.exists():
        return path, None
    return path, json.loads(path.read_text(encoding="utf-8"))


def append(a: argparse.Namespace) -> int:
    evidence_dir = Path(a.evidence_dir)
    try:
        artifact_paths = json.loads(a.artifact_paths)
        if not isinstance(artifact_paths, dict):
            raise ValueError("must be a JSON object")
    except Exception as exc:
        return _fail(f"--artifact-paths must be a JSON object: {exc}", 2)
    event = {
        "schema_version": "parallax-run-evidence-event-v1",
        "run_id": a.run_id,
        "slug": a.slug,
        "at": a.at or _now(),
        "event_type": a.event_type,
        "actor": a.actor,
        "summary": a.summary,
        "artifact_paths": artifact_paths,
    }
    for key, val in (("agent_type", a.agent_type), ("agent_id", a.agent_id),
                     ("worktree", a.worktree), ("branch", a.branch), ("commit", a.commit)):
        if val is not None:
            event[key] = val
    try:
        _validate(event, EVENT_SCHEMA)
    except EnvironmentError as exc:
        return _fail(str(exc), 3)
    except Exception as exc:
        return _fail(f"event failed schema validation — nothing written: {exc}", 2)
    try:
        _, run_doc = _load_run_evidence(evidence_dir)
    except Exception as exc:
        return _fail(f"cannot read run-evidence.json next to the timeline: {exc}", 2)
    if run_doc is not None:
        run = run_doc.get("run", {})
        if run.get("run_id") != a.run_id or run.get("slug") != a.slug:
            return _fail(
                f"event run_id/slug ({a.run_id!r}/{a.slug!r}) do not match run-evidence.json "
                f"({run.get('run_id')!r}/{run.get('slug')!r}) — refusing to file an event under another run",
                2,
            )
    events_path = evidence_dir / "events.jsonl"
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with open(events_path, "a", encoding="utf-8") as handle:  # append-only, never truncate
        handle.write(json.dumps(event, ensure_ascii=True, sort_keys=True) + "\n")
    print(json.dumps({"appended": a.event_type, "at": event["at"], "events_jsonl": str(events_path)}))
    return 0


def update_run(a: argparse.Namespace) -> int:
    evidence_dir = Path(a.evidence_dir)
    path, doc = _load_run_evidence(evidence_dir)
    if doc is None:
        return _fail(f"{path} does not exist — update-run only updates an existing run-evidence.json "
                     "(creation is Phase 1's wiring)", 2)
    run = doc.get("run")
    if not isinstance(run, dict):
        return _fail("run-evidence.json has no 'run' object", 2)
    if a.run_id is not None and run.get("run_id") != a.run_id:
        return _fail(f"run-evidence run_id {run.get('run_id')!r} != --run-id {a.run_id!r}", 2)
    if a.slug is not None and run.get("slug") != a.slug:
        return _fail(f"run-evidence slug {run.get('slug')!r} != --slug {a.slug!r}", 2)
    if a.status is not None:
        run["status"] = a.status
    run["updated_at"] = _now()
    repo = doc.get("repo")
    if isinstance(repo, dict):
        if a.feature_tip is not None:
            repo["feature_tip"] = a.feature_tip
        if a.dirty_at_end is not None:
            repo["dirty_at_end"] = a.dirty_at_end == "true"
    if a.transcript_path is not None:
        # v0.37.5 D3 — provenance accuracy: the transcript pointer must name the .jsonl itself,
        # not the session container directory (the RUN2 defect). Auxiliary provenance only.
        if not a.transcript_path.endswith(".jsonl"):
            return _fail(f"--transcript-path must point at the session .jsonl itself, not a "
                         f"directory ({a.transcript_path!r}) — v0.37.5 D3", 2)
        if not isinstance(doc.get("provenance"), dict):   # Gap-4: provenance may be an explicit null
            doc["provenance"] = {}
        doc["provenance"]["transcript_path"] = a.transcript_path
    try:
        _validate(doc, RUN_SCHEMA)
    except EnvironmentError as exc:
        return _fail(str(exc), 3)
    except Exception as exc:
        return _fail(f"updated run-evidence.json fails schema validation — nothing written: {exc}", 2)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, ensure_ascii=True, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(json.dumps({"updated": str(path), "status": run["status"], "updated_at": run["updated_at"]}))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subs = root.add_subparsers(dest="command", required=True)

    p_a = subs.add_parser("append", help="append one schema-valid event to events.jsonl")
    p_a.add_argument("evidence_dir", help=".parallax/<slug>/evidence directory")
    p_a.add_argument("--run-id", required=True)
    p_a.add_argument("--slug", required=True)
    p_a.add_argument("--event-type", required=True)
    p_a.add_argument("--actor", required=True)
    p_a.add_argument("--summary", required=True)
    p_a.add_argument("--artifact-paths", default="{}",
                     help='JSON object of artifact paths behind the event (default {}) — '
                          'a summary is not proof when a file/log exists')
    p_a.add_argument("--at", default=None, help="ISO timestamp override (default: now, UTC)")
    p_a.add_argument("--agent-type", default=None)
    p_a.add_argument("--agent-id", default=None)
    p_a.add_argument("--worktree", default=None)
    p_a.add_argument("--branch", default=None)
    p_a.add_argument("--commit", default=None)
    p_a.set_defaults(func=append)

    p_u = subs.add_parser("update-run", help="update run-evidence.json status/timestamps in place")
    p_u.add_argument("evidence_dir", help=".parallax/<slug>/evidence directory")
    p_u.add_argument("--status", default=None,
                     help="new run.status (validated against assets/run-evidence.schema.json)")
    p_u.add_argument("--run-id", default=None, help="assert the file's run_id before touching it")
    p_u.add_argument("--slug", default=None, help="assert the file's slug before touching it")
    p_u.add_argument("--feature-tip", default=None)
    p_u.add_argument("--dirty-at-end", default=None, choices=["true", "false"])
    p_u.add_argument("--transcript-path", dest="transcript_path", default=None,
                     help="v0.37.5 D3: auxiliary provenance — must be the session .jsonl itself, "
                          "never a container directory")
    p_u.set_defaults(func=update_run)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # unreadable schema/target etc. — fail closed, never half-write
        return _fail(f"{type(exc).__name__}: {exc}", 3)


if __name__ == "__main__":
    raise SystemExit(main())
