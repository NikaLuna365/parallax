#!/usr/bin/env python3
"""Parallax hand-driven / degraded finalize gate (v0.39 §5.1) — make the v0.38 gates fire on the box.

The whole v0.38.1 production window was HAND-DRIVEN: verdicts hand-committed as reviews/*.raw.json,
no run-state.json / events.jsonl, no merge-ledger/triage gate, E1 never enforced, the detached-HEAD
hazard B1 mechanizes caught by a human not the machinery. The gates all EXIST and are harness-green —
nothing routed the hand path through them. This is the single reachable entry that does, invoked by
/parallax:run's done-gate under `--finalize` (or auto-detected on a hand-integrated slice) — NOT a new
command. It REUSES the existing gates rather than re-implementing them, and FAILS CLOSED on any.

Per slice, in order (each fails closed, exit 2):
  HG3  stale tip — `git rev-parse <branch>` must equal --recorded-tip (the B1 invariant on the hand
       path: run-state is a checkpoint, git is the truth). A lagging/advanced ref refuses.
  HG2  verdict gate — the hand-committed post-green raw verdict is routed through merge-ledger.py
       (schema-gate: a malformed/hand-authored verdict is a PROVIDER ERROR, rejected, never merged)
       and then triage.py (must dispose GREEN under the pinned policy). Either failure refuses.
  HG1  evidence — only AFTER HG2 gates the verdict GREEN, emit the adopt-critical receipts
       (slice_dispatched + arbiter_green) into events.jsonl, then run evidence-event.py audit-slice;
       an integrated slice still missing its receipts fails closed (E1 on the hand path).
Then (§5.5) re-stamp run-evidence.json to the live plugin version + a non-frozen status, if present.

Exit: 0 slice finalizes cleanly; 2 fail-closed (stale tip / rejected verdict / missing receipt);
3 bad input (not a git repo, missing sibling script).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE_EVENT = ROOT / "scripts" / "evidence-event.py"
MERGE_LEDGER = ROOT / "scripts" / "merge-ledger.py"
TRIAGE = ROOT / "scripts" / "triage.py"


def _emit(msg, code):
    print(json.dumps(msg))
    return code


def _git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def _run(pyargs):
    p = subprocess.run([sys.executable, *[str(x) for x in pyargs]], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


def finalize(a) -> int:
    if _git(a.repo, "rev-parse", "--git-dir").returncode != 0:
        return _emit({"error": f"{a.repo!r} is not a git repository"}, 3)
    report = {"slice": a.slice, "slug": a.slug, "gates": {}}

    # --- HG3: stale-tip refusal (B1 invariant on the hand path) ---
    live = _git(a.repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{a.branch}")
    if live.returncode != 0:
        report["gates"]["HG3"] = "fail: branch does not exist"
        return _emit({**report, "error": f"HG3: branch {a.branch!r} not found"}, 2)
    live_tip = live.stdout.strip()
    if live_tip != a.recorded_tip and not (live_tip.startswith(a.recorded_tip) or a.recorded_tip.startswith(live_tip)):
        report["gates"]["HG3"] = "fail: stale tip"
        return _emit({**report, "error": f"HG3: recorded_tip {a.recorded_tip} != git rev-parse {a.branch} "
                      f"({live_tip}) — a stale checkpoint over git; finalize refuses (v0.39 §5.1 HG3 / B1)"}, 2)
    report["gates"]["HG3"] = "ok"

    # --- HG2: route the hand-committed raw verdict through the merge-ledger + triage schema-gate ---
    ml = [MERGE_LEDGER, a.ledger, a.raw_verdict, "--slice", a.slice, "--current-diff", a.current_diff,
          "--raw-response", a.raw_verdict]
    if a.slug:
        ml += ["--slug", a.slug]
    if a.pinned_policy:
        ml += ["--pinned-policy", a.pinned_policy]
    if a.repo_root:
        ml += ["--repo-root", a.repo_root]
    if a.contract_hash:
        ml += ["--contract-hash", a.contract_hash]
    mrc, mout = _run(ml)
    if mrc != 0:
        report["gates"]["HG2"] = "fail: verdict rejected by merge-ledger"
        return _emit({**report, "error": "HG2: the hand-committed post-green verdict was REJECTED by "
                      "merge-ledger.py (malformed / hand-authored = provider error, never a merge-unblock "
                      "v0.39 §5.1 HG2)", "merge_ledger": mout[-600:]}, 2)
    tr = [TRIAGE, a.ledger, "--current-diff", a.current_diff]
    if a.pinned_policy:
        tr += ["--pinned-policy", a.pinned_policy]
    if a.policy:
        tr += ["--policy", a.policy]
    trc, tout = _run(tr)
    if trc != 0:
        report["gates"]["HG2"] = "fail: triage not green"
        return _emit({**report, "error": "HG2: triage.py did not dispose GREEN under the pinned policy — "
                      "the verdict does not unblock a merge (v0.39 §5.1 HG2)", "triage": tout[-600:]}, 2)
    report["gates"]["HG2"] = "ok"

    # --- HG1: emit the adopt-critical receipts, THEN audit-slice (E1 on the hand path) ---
    if not a.no_emit:
        for etype, actor, summ in (
            ("slice_dispatched", "main", f"{a.slice}: hand-driven finalize — slice recorded at dispatch"),
            ("arbiter_green", "arbiter", f"{a.slice}: hand-driven finalize — verdict gated GREEN via merge-ledger/triage"),
        ):
            erc, eout = _run([EVIDENCE_EVENT, "append", a.evidence_dir, "--run-id", a.run_id,
                              "--slug", a.slug, "--event-type", etype, "--actor", actor,
                              "--summary", summ, "--artifact-paths", json.dumps({"raw_verdict": a.raw_verdict})])
            if erc != 0:
                report["gates"]["HG1"] = "fail: could not emit receipt"
                return _emit({**report, "error": f"HG1: failed to emit {etype} ({eout[-300:]})"}, 2)
    arc, aout = _run([EVIDENCE_EVENT, "audit-slice", a.evidence_dir, "--slice", a.slice, "--slug", a.slug])
    if arc != 0:
        report["gates"]["HG1"] = "fail: audit-slice fail-closed"
        return _emit({**report, "error": "HG1: evidence-event.py audit-slice FAILED CLOSED — the "
                      "integrated slice lacks its adopt-critical receipts (v0.39 §5.1 HG1 / E1)",
                      "audit": aout[-400:]}, 2)
    report["gates"]["HG1"] = "ok"

    # --- §5.5: re-stamp telemetry to the live plugin version (if run-evidence.json exists) ---
    re_path = Path(a.evidence_dir) / "run-evidence.json"
    if re_path.exists():
        _run([EVIDENCE_EVENT, "update-run", a.evidence_dir, "--restamp-version",
              "--status", "complete", "--run-id", a.run_id, "--slug", a.slug])
        report["telemetry"] = "restamped run-evidence version+status"

    return _emit({**report, "verdict": "finalized"}, 0)


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Parallax v0.39 hand-driven finalize gate (HG1/HG2/HG3).")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--evidence-dir", dest="evidence_dir", required=True)
    ap.add_argument("--run-id", dest="run_id", required=True)
    ap.add_argument("--slice", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--recorded-tip", dest="recorded_tip", required=True)
    ap.add_argument("--raw-verdict", dest="raw_verdict", required=True,
                    help="the hand-committed post-green raw provider verdict (reviews/<slice>.raw.json)")
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--current-diff", dest="current_diff", required=True)
    ap.add_argument("--pinned-policy", dest="pinned_policy", default=None)
    ap.add_argument("--policy", default=None)
    ap.add_argument("--repo-root", dest="repo_root", default=None)
    ap.add_argument("--contract-hash", dest="contract_hash", default=None)
    ap.add_argument("--session-id", dest="session_id", default=None)
    ap.add_argument("--no-emit", dest="no_emit", action="store_true",
                    help="(testing) skip emitting receipts, to prove audit-slice fails closed without them")
    a = ap.parse_args(argv)
    return finalize(a)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
