#!/usr/bin/env python3
"""Parallax resume reconciliation (v0.37.5 6.1 / F7 NEW-MODE, gate B1).

The v0.37.4 live failure this closes: `run-state.json` recorded S6's `test_tip` at
`ced5b80`, but across a session boundary the real branch advanced three commits
(`ced5b80 -> c0f4806 -> 3966cb0 -> 93d6312`, including two arbiter RED rounds and a
re-blindfold) that were never written back. A resumer trusting the checkpoint verbatim
would check out an arbiter-rejected tree and silently discard ~40 diagnosed fixes.

Rule: run-state is a CHECKPOINT, git is the TRUTH. On every resume/handoff, each
non-terminal slice's recorded `code_tip`/`test_tip` is reconciled against the live
`git rev-parse` of its track branches:

  * all equal                -> exit 0 (proceed; nothing written);
  * drift + --write-back     -> the REAL tips are written back into run-state.json
                                (updated_at refreshed), the drift report is printed, and
                                exit 0 — the caller MUST then emit a `session_handoff`
                                evidence event carrying the report and re-commit the
                                checkpoint before dispatching anything;
  * drift, no --write-back   -> exit 2 (fail closed) with the exact per-slice drift so a
                                human/orchestrator reconciles deliberately. Run-state is
                                NEVER silently trusted over git.

Branch naming (matching commands/run.md): sequential tracks
`<prefix><slug>-code` / `<prefix><slug>-test`; parallel per-slice tracks
`<prefix><slug>-<SID>-code` / `<prefix><slug>-<SID>-test`. For each slice the parallel
name is preferred when it exists; a recorded tip whose branch no longer exists at all is
drift too (reported as `missing-branch`).

Exit: 0 consistent (or reconciled via --write-back); 2 drift without write-back;
3 bad input (unreadable run-state / not a git repo) — fail closed.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _rev(repo: str, ref: str):
    p = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{ref}"],
                       capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _track_tip(repo: str, prefix: str, slug: str, sid: str, side: str):
    for ref in (f"{prefix}{slug}-{sid}-{side}", f"{prefix}{slug}-{side}"):
        tip = _rev(repo, ref)
        if tip is not None:
            return ref, tip
    return None, None


def reconcile(repo: str, run_state_path: Path, prefix: str, write_back: bool):
    try:
        state = json.loads(run_state_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return 3, {"error": f"cannot read run-state {run_state_path}: {exc}"}
    if _rev(repo, "HEAD") is None and subprocess.run(
            ["git", "-C", repo, "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
        return 3, {"error": f"{repo!r} is not a git repository"}
    slug = state.get("slug")
    drift = []
    for s in state.get("slices", []):
        if s.get("status") in ("integrated", "parked"):
            continue  # terminal for resume purposes; tips no longer drive work
        sid = s.get("id")
        for side, key in (("code", "code_tip"), ("test", "test_tip")):
            recorded = s.get(key)
            if not recorded:
                continue
            ref, live = _track_tip(repo, prefix, slug, sid, side)
            if live is None:
                drift.append({"slice": sid, "side": side, "recorded": recorded,
                              "live": None, "branch": None, "kind": "missing-branch"})
                continue
            if not (live == recorded or live.startswith(recorded) or recorded.startswith(live)):
                entry = {"slice": sid, "side": side, "recorded": recorded, "live": live,
                         "branch": ref, "kind": "tip-drift"}
                if write_back:
                    s[key] = live
                drift.append(entry)
    if not drift:
        return 0, {"verdict": "consistent", "slug": slug,
                   "note": "recorded tips match live git branch tips; proceed"}
    if write_back:
        blocked = [d for d in drift if d["kind"] == "missing-branch"]
        if blocked:
            return 2, {"verdict": "drift", "slug": slug, "drift": drift,
                       "error": "cannot write back a missing branch — human reconciliation required"}
        state["updated_at"] = _now()
        tmp = run_state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
                       encoding="utf-8")
        tmp.replace(run_state_path)
        return 0, {"verdict": "reconciled", "slug": slug, "drift": drift,
                   "action": "run-state tips written back from git (git is the truth); "
                             "now emit a session_handoff event carrying this report and "
                             "re-commit the checkpoint BEFORE dispatching anything"}
    return 2, {"verdict": "drift", "slug": slug, "drift": drift,
               "error": "run-state tips != live git tips — a resume must NOT trust this "
                        "checkpoint verbatim (v0.37.5 6.1 / F7). Re-run with --write-back to "
                        "adopt the real tips, or reconcile by hand"}


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37.5 resume reconciliation (git is the truth).")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--run-state", default=None, help="default: <repo>/.parallax/<slug>/run-state.json")
    ap.add_argument("--prefix", default="feature/", help="branch prefix (codex.toml [git] branch_prefix)")
    ap.add_argument("--write-back", action="store_true",
                    help="adopt the live git tips into run-state (the caller must then emit "
                         "session_handoff and re-commit the checkpoint)")
    a = ap.parse_args(argv)
    rs = Path(a.run_state) if a.run_state else Path(a.repo) / ".parallax" / a.slug / "run-state.json"
    code, detail = reconcile(a.repo, rs, a.prefix, a.write_back)
    print(json.dumps(detail))
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
