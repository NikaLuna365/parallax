#!/usr/bin/env python3
"""Parallax dispatched-subagent manifest helper (v0.38 F8) — the enabling artifact for --adopt.

The v0.37.4 RUN2 gap this closes: S6's blind tracks were dispatched as BACKGROUND agents in
one session; their completion notifications do not cross a session boundary, and there was no
machine record of what was dispatched, on what branch, expecting what commit, in which session.
The operator reconstructed it by hand into RUN-HANDOFF.md. This helper makes that record
deterministic: /parallax:run writes an entry AT DISPATCH (Step 2a) and updates it as tracks
report; the manifest is committed to feature/<slug> so it survives a session boundary and a
fresh cloud clone.

Subcommands:
  record     append-or-UPDATE one (slice, role) entry in .parallax/<slug>/subagents.json.
             - creates the file (with run_id/slug) when missing;
             - if the file exists its run_id/slug must match (exit 2 on mismatch — a manifest
               cannot be filed under another run);
             - a re-dispatch of the same (slice, role) updates that entry in place (never a
               duplicate), so the manifest always names the CURRENT in-flight state;
             - validates the whole manifest against assets/subagents.schema.json BEFORE writing
               (fail closed: an invalid manifest writes nothing, exit 2).
  reconcile  resolve every entry's branch against LIVE git (git is the truth):
             - a branch that no longer exists  -> the entry is STALE (never silently trusted);
             - a branch whose live tip is a descendant of wave_base -> reap-eligible, the live
               tip is reported as reported_commit (the missed cross-session notification,
               replaced by reading git);
             - a branch whose live tip == wave_base -> carries no work yet;
             - a live tip that CONFLICTS with a recorded reported_commit (neither is an ancestor
               of the other) -> reported as a conflict (adopt fails closed on it).
             With --write-back the reap/stale status + reported_commit are persisted (validated).
             Emits a JSON report. This is what /parallax:run --adopt reads to reconstruct the
             in-flight background tracks.

This is an auditability + recovery mechanism, not a benchmark: it records what was DISPATCHED.
Missing data stays null/absent, never invented (v0.36 contract). It never asserts a slice is
verified — that remains the arbiter/verifier receipts.

Exit: 0 ok; 2 invalid input / schema failure / run mismatch (fail closed — nothing written);
3 bad environment (missing jsonschema, not a git repo, unreadable target).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "assets" / "subagents.schema.json"

REAP_ROLES = ("test-writer", "blind-coder")  # the in-flight tracks adopt reaps


def _fail(msg: str, code: int) -> int:
    print(json.dumps({"error": msg}))
    return code


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _validate(doc) -> None:
    try:
        import jsonschema
    except ImportError as exc:
        raise EnvironmentError(f"jsonschema is required; refusing an unvalidated manifest write: {exc}")
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    jsonschema.validate(doc, schema)


def _load(path: Path):
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, doc) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def _rev(repo: str, branch: str):
    p = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
                       capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _is_ancestor(repo: str, a: str, b: str) -> bool:
    """True if commit a is an ancestor of commit b (a == b counts as ancestor)."""
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", a, b],
                          capture_output=True).returncode == 0


def _is_git_repo(repo: str) -> bool:
    return subprocess.run(["git", "-C", repo, "rev-parse", "--git-dir"], capture_output=True).returncode == 0


def record(a: argparse.Namespace) -> int:
    path = Path(a.manifest)
    try:
        doc = _load(path)
    except Exception as exc:
        return _fail(f"cannot read manifest {path}: {exc}", 2)
    if doc is None:
        doc = {"schema_version": "parallax-subagents-v1", "run_id": a.run_id, "slug": a.slug, "entries": []}
    else:
        if doc.get("run_id") != a.run_id or doc.get("slug") != a.slug:
            return _fail(
                f"manifest run_id/slug ({doc.get('run_id')!r}/{doc.get('slug')!r}) != "
                f"--run-id/--slug ({a.run_id!r}/{a.slug!r}) — refusing to file a track under another run",
                2,
            )
    entry = {
        "slice": a.slice,
        "role": a.role,
        "branch": a.branch,
        "wave_base": a.wave_base,
        "dispatched_at": a.dispatched_at or _now(),
        "session_id": a.session_id,
        "mode": a.mode,
        "status": a.status,
    }
    if a.reported_commit is not None:
        entry["reported_commit"] = a.reported_commit
    entries = doc.setdefault("entries", [])
    for i, e in enumerate(entries):
        if e.get("slice") == a.slice and e.get("role") == a.role:
            # update in place; keep a prior dispatched_at unless a new one was passed explicitly
            if a.dispatched_at is None and e.get("dispatched_at"):
                entry["dispatched_at"] = e["dispatched_at"]
            # keep a known reported_commit if this call didn't supply one
            if a.reported_commit is None and e.get("reported_commit") is not None:
                entry["reported_commit"] = e["reported_commit"]
            entries[i] = entry
            break
    else:
        entries.append(entry)
    try:
        _validate(doc)
    except EnvironmentError as exc:
        return _fail(str(exc), 3)
    except Exception as exc:
        return _fail(f"manifest failed schema validation — nothing written: {exc}", 2)
    _write(path, doc)
    print(json.dumps({"recorded": {"slice": a.slice, "role": a.role, "status": a.status},
                      "manifest": str(path), "entries": len(entries)}))
    return 0


def reconcile(a: argparse.Namespace) -> int:
    path = Path(a.manifest)
    try:
        doc = _load(path)
    except Exception as exc:
        return _fail(f"cannot read manifest {path}: {exc}", 2)
    if doc is None:
        return _fail(f"no manifest at {path}", 2)
    if not _is_git_repo(a.repo):
        return _fail(f"{a.repo!r} is not a git repository", 3)
    try:
        _validate(doc)
    except EnvironmentError as exc:
        return _fail(str(exc), 3)
    except Exception as exc:
        return _fail(f"manifest on disk fails schema validation: {exc}", 2)

    report = []
    any_stale = False
    any_conflict = False
    for e in doc.get("entries", []):
        branch = e.get("branch")
        wave_base = e.get("wave_base")
        recorded = e.get("reported_commit")
        live = _rev(a.repo, branch)
        row = {"slice": e.get("slice"), "role": e.get("role"), "branch": branch,
               "wave_base": wave_base, "prior_status": e.get("status"),
               "recorded_commit": recorded, "live_tip": live}
        if live is None:
            row["resolved"] = False
            row["kind"] = "missing-branch"
            row["reap_eligible"] = False
            any_stale = True
            if a.write_back:
                e["status"] = "stale"
        else:
            ahead = _is_ancestor(a.repo, wave_base, live) and live != wave_base
            row["resolved"] = True
            row["ahead_of_wave_base"] = ahead
            # conflict: a recorded commit that neither contains nor is contained by the live tip
            conflict = (recorded is not None
                        and not (live.startswith(recorded) or recorded.startswith(live))
                        and not _is_ancestor(a.repo, recorded, live))
            row["conflict"] = conflict
            if conflict:
                any_conflict = True
                row["kind"] = "tip-conflict"
                row["reap_eligible"] = False
            elif ahead and e.get("role") in REAP_ROLES:
                row["kind"] = "reap-eligible"
                row["reap_eligible"] = True
                if a.write_back:
                    e["status"] = "reaped"
                    e["reported_commit"] = live
            else:
                row["kind"] = "no-work" if not ahead else "present"
                row["reap_eligible"] = False
        report.append(row)

    if a.write_back:
        try:
            _validate(doc)
        except Exception as exc:
            return _fail(f"reconciled manifest fails schema validation — nothing written: {exc}", 2)
        _write(path, doc)

    print(json.dumps({"verdict": "reconciled" if a.write_back else "report",
                      "slug": doc.get("slug"), "run_id": doc.get("run_id"),
                      "any_stale": any_stale, "any_conflict": any_conflict,
                      "entries": report}))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subs = root.add_subparsers(dest="command", required=True)

    p_r = subs.add_parser("record", help="append-or-update one (slice, role) dispatch entry")
    p_r.add_argument("manifest", help=".parallax/<slug>/subagents.json")
    p_r.add_argument("--run-id", required=True)
    p_r.add_argument("--slug", required=True)
    p_r.add_argument("--slice", required=True)
    p_r.add_argument("--role", required=True, choices=["test-writer", "blind-coder", "arbiter", "codex-judge"])
    p_r.add_argument("--branch", required=True)
    p_r.add_argument("--wave-base", dest="wave_base", required=True)
    p_r.add_argument("--session-id", dest="session_id", required=True)
    p_r.add_argument("--mode", required=True, choices=["foreground", "background"])
    p_r.add_argument("--status", default="dispatched", choices=["dispatched", "reported", "reaped", "stale"])
    p_r.add_argument("--reported-commit", dest="reported_commit", default=None)
    p_r.add_argument("--dispatched-at", dest="dispatched_at", default=None,
                     help="ISO timestamp override (default: now, UTC)")
    p_r.set_defaults(func=record)

    p_c = subs.add_parser("reconcile", help="resolve every entry against live git (git is the truth)")
    p_c.add_argument("manifest", help=".parallax/<slug>/subagents.json")
    p_c.add_argument("--repo", default=".")
    p_c.add_argument("--write-back", action="store_true",
                     help="persist reaped/stale status + reported_commit into the manifest")
    p_c.set_defaults(func=reconcile)
    return root


def main(argv) -> int:
    args = parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # unreadable schema/target etc. — fail closed, never half-write
        return _fail(f"{type(exc).__name__}: {exc}", 3)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
