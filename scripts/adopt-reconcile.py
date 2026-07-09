#!/usr/bin/env python3
"""Parallax adopt reconciler (v0.38 §5.2) — recover an UNCLEANLY-interrupted run, git-first.

`--resume` handles the CLEAN limit-pause (`status=paused-on-limit`, an eager checkpoint, an
exact per-slice tip resume). This closes the OTHER case: a run that died mid-build in one
session — `status=running`, no clean pause — with one or more blind tracks left as IN-FLIGHT
BACKGROUND branches whose completion notifications never crossed the session boundary (the
v0.37.4 RUN2 story: the operator hand-wrote RUN-HANDOFF.md and did manual git archaeology
because nothing machine-recorded what was dispatched or where it landed).

This reconciler reconstructs the truth from git + the dispatched-subagent manifest
(subagents.json, F8) + the v0.37.5-reconciled checkpoint, then classifies every slice so the
build loop can continue idempotently — and it FAILS CLOSED on anything it cannot resolve.

It COMPOSES the two existing git-first reconcilers (it does NOT re-implement them):
  * scripts/resume-reconcile.py  — v0.37.5 F7: run-state tips are a checkpoint, GIT IS THE
    TRUTH; drift is written back from git (or a missing branch refuses silent write-back).
  * scripts/subagent-manifest.py — v0.38 F8: reap in-flight background tracks (branch ahead of
    wave_base -> reported_commit read off git), mark a vanished branch STALE, flag a tip that
    conflicts with a recorded reported_commit.

Order (safety first):
  1. LEASE. If run-state carries a LIVE lock (expires_at in the future) -> REFUSE (exit 2):
     another session may be active; a resume/adopt steals only an EXPIRED lease. (The git-ref
     steal itself is run.md's job; this gate decides whether it is permitted.)
  2. TIP RECONCILE (F7). git wins over recorded tips; a missing branch is captured, never
     silently trusted.
  3. MANIFEST RECONCILE (F8). reap ahead-of-wave_base background tracks; stale a vanished
     branch; surface a tip-conflict.
  4. CLASSIFY each slice (reading git tips directly — run-state tips are not trusted):
       integrated               -> skip (never redone);                         [A2]
       green-unverified         -> run ONLY the owed verification;
       in_progress, both tracks ahead of wave_base -> reap + carry to assembly; [A3]
       in_progress, one track missing/no-work      -> re-dispatch ONLY that track, blind; the
                                                       present track is kept;    [A4]
       in_progress, NEITHER track carries work      -> ESCALATE (never guess);   [A5]
       a tip-conflict on any track                  -> ESCALATE (never guess);   [A5]
       pending                  -> dispatch as deps integrate.
  5. If any slice escalates (or the lease is live) -> write the escalation and exit 2. Adopt
     NEVER marks a slice done without its arbiter/verifier receipts and NEVER fabricates a track.

Exit: 0 adoptable (report on stdout); 2 fail-closed (refuse live lease / escalate irreconcilable);
3 bad input (unreadable run-state, not a git repo, missing jsonschema for the composed helpers).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESUME_RECONCILE = ROOT / "scripts" / "resume-reconcile.py"
SUBAGENT_MANIFEST = ROOT / "scripts" / "subagent-manifest.py"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(s: str):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def _rev(repo: str, branch: str):
    p = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
                       capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def _is_ancestor(repo: str, a: str, b: str) -> bool:
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", a, b],
                          capture_output=True).returncode == 0


def _is_git_repo(repo: str) -> bool:
    return subprocess.run(["git", "-C", repo, "rev-parse", "--git-dir"], capture_output=True).returncode == 0


def _track(repo: str, prefix: str, slug: str, sid: str, side: str):
    """Resolve a slice's track branch tip, preferring the parallel per-slice name."""
    for ref in (f"{prefix}{slug}-{sid}-{side}", f"{prefix}{slug}-{side}"):
        tip = _rev(repo, ref)
        if tip is not None:
            return ref, tip
    return None, None


def _run(pyargs):
    p = subprocess.run([sys.executable, *pyargs], capture_output=True, text=True)
    try:
        detail = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
    except Exception:
        detail = {"raw": p.stdout, "stderr": p.stderr}
    return p.returncode, detail


def adopt(a: argparse.Namespace):
    repo = a.repo
    rs_path = Path(a.run_state) if a.run_state else Path(repo) / ".parallax" / a.slug / "run-state.json"
    manifest_path = Path(a.manifest) if a.manifest else Path(repo) / ".parallax" / a.slug / "subagents.json"
    try:
        state = json.loads(rs_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return 3, {"error": f"cannot read run-state {rs_path}: {exc}"}
    if not _is_git_repo(repo):
        return 3, {"error": f"{repo!r} is not a git repository"}

    report = {"verdict": None, "slug": a.slug, "run_id": state.get("run_id"),
              "continue_command": f"/parallax:run --adopt {a.slug}"}
    prior_status = state.get("status")
    escalations = []

    # --- 1) LEASE: refuse a LIVE lease; an expired one is stealable (run.md does the git steal).
    now = _parse_iso(a.now) if a.now else datetime.now(timezone.utc)
    lock = state.get("lock")
    if isinstance(lock, dict):
        exp = _parse_iso(lock.get("expires_at", ""))
        if exp is not None and now is not None and exp > now:
            report["verdict"] = "refuse-live-lease"
            report["lease"] = {"holder": lock.get("holder"), "expires_at": lock.get("expires_at"),
                               "now": now.isoformat()}
            report["reason"] = ("a LIVE lease is held (expires_at is in the future) — another session "
                                "may be active; adopt refuses and steals only an EXPIRED lease")
            return 2, report
        report["lease"] = {"holder": lock.get("holder"), "expires_at": lock.get("expires_at"),
                           "state": "expired-stealable"}
    else:
        report["lease"] = {"state": "none"}

    # --- 2) TIP RECONCILE (F7): git wins over recorded tips. Consume resume-reconcile, never redo it.
    rc, detail = _run([str(RESUME_RECONCILE), "--repo", repo, "--slug", a.slug,
                       "--prefix", a.prefix, "--run-state", str(rs_path), "--write-back"])
    if rc == 3:
        return 3, {"error": "tip reconciliation failed (bad input)", "tip_reconcile": detail}
    report["tip_reconcile"] = {"rc": rc, "detail": detail}
    # rc==0: tips reconciled/consistent (run-state now git-true). rc==2: a missing branch blocked
    # F7's all-or-nothing write-back — NOT fatal here (classification reads git directly), but note it.
    if rc == 2:
        report["tip_reconcile"]["note"] = ("F7 refused a partial write-back because a recorded branch "
                                           "is missing; classification below reads git directly")
        # reload state (F7 may have written nothing on rc==2)
    try:
        state = json.loads(rs_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return 3, {"error": f"cannot re-read run-state after tip reconcile: {exc}"}

    # --- 3) MANIFEST RECONCILE (F8): reap background tracks; stale a vanished branch; flag conflicts.
    manifest = None
    if manifest_path.exists():
        mrc, mdetail = _run([str(SUBAGENT_MANIFEST), "reconcile", str(manifest_path),
                             "--repo", repo, "--write-back"])
        if mrc == 3:
            return 3, {"error": "manifest reconciliation failed (bad environment)", "manifest_reconcile": mdetail}
        report["manifest_reconcile"] = mdetail
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            manifest = None
    else:
        report["manifest_reconcile"] = None
        report["manifest_note"] = ("no subagents.json — adopt proceeds from run-state + git, but has "
                                   "no record of in-flight BACKGROUND tracks (F8 is the enabling artifact)")

    # index manifest conflicts / reaps by (slice, role)
    m_by_key = {}
    if isinstance(report.get("manifest_reconcile"), dict):
        for row in report["manifest_reconcile"].get("entries", []):
            m_by_key[(row.get("slice"), row.get("role"))] = row

    integrated_set = set(state.get("integrated", []))

    # --- 4) CLASSIFY every slice, reading git tips directly.
    slice_reports = []
    for s in state.get("slices", []):
        sid = s.get("id")
        status = s.get("status")
        wave_base = s.get("wave_base") or state.get("base_tip")
        row = {"id": sid, "recorded_status": status}

        if status == "integrated" or sid in integrated_set:
            row["class"] = "integrated"; row["action"] = "skip"                       # [A2]
            slice_reports.append(row); continue
        if status == "parked":
            row["class"] = "parked"; row["action"] = "leave-for-resolve"
            slice_reports.append(row); continue
        if status == "green-unverified":
            row["class"] = "green-unverified"; row["action"] = "run-owed-verification-only"
            row["verified_diff"] = s.get("verified_diff"); row["arbiter_verdict"] = s.get("arbiter_verdict")
            slice_reports.append(row); continue

        # in_progress or pending: resolve the two track branches from git
        cref, ctip = _track(repo, a.prefix, a.slug, sid, "code")
        tref, ttip = _track(repo, a.prefix, a.slug, sid, "test")

        def _work(tip):
            return tip is not None and _is_ancestor(repo, wave_base, tip) and tip != wave_base

        code_work = _work(ctip)
        test_work = _work(ttip)
        row["code"] = {"branch": cref, "tip": ctip, "carries_work": code_work}
        row["test"] = {"branch": tref, "tip": ttip, "carries_work": test_work}

        # a manifest tip-conflict on either track is irreconcilable -> escalate  [A5]
        conflict_roles = [rl for (sl, rl), r in m_by_key.items()
                          if sl == sid and r.get("kind") == "tip-conflict"]
        if conflict_roles:
            row["class"] = "escalate"
            row["reason"] = (f"a recorded reported_commit conflicts irreconcilably with the live branch "
                             f"tip for {sorted(conflict_roles)} — two candidate tips, neither an ancestor "
                             f"of the other; adopt does not guess")
            escalations.append({"slice": sid, "reason": row["reason"]})
            slice_reports.append(row); continue

        if status == "in_progress":
            if code_work and test_work:
                row["class"] = "in_progress_recoverable"                              # [A3]
                row["action"] = "reap-and-assemble"
            elif code_work or test_work:
                missing = "test" if code_work else "code"                             # [A4]
                row["class"] = "in_progress_missing_track"
                row["action"] = "redispatch-blind"
                row["redispatch"] = [missing]
                row["keep_present"] = "code" if code_work else "test"
            else:
                row["class"] = "escalate"                                             # [A5]
                row["reason"] = ("slice is in_progress but NEITHER track branch carries a commit ahead of "
                                 "wave_base (both missing/empty) — nothing recoverable; adopt escalates "
                                 "rather than fabricate a track or mark it done")
                escalations.append({"slice": sid, "reason": row["reason"]})
        else:  # pending
            if code_work or test_work:
                # a 'pending' slice that nonetheless has work on a track is a state inconsistency
                row["class"] = "in_progress_recoverable" if (code_work and test_work) else "in_progress_missing_track"
                row["action"] = "reap-and-assemble" if (code_work and test_work) else "redispatch-blind"
                if row["class"] == "in_progress_missing_track":
                    row["redispatch"] = ["test" if code_work else "code"]
                    row["keep_present"] = "code" if code_work else "test"
            else:
                row["class"] = "pending"; row["action"] = "dispatch-when-deps-integrate"
        slice_reports.append(row)

    report["slices"] = slice_reports
    report["escalations"] = escalations

    # --- 5) FAIL CLOSED on any escalation.
    if escalations:
        report["verdict"] = "escalate"
        if a.write_back:
            esc_path = Path(a.escalations) if a.escalations else Path(repo) / ".parallax" / a.slug / "escalations.md"
            esc_path.parent.mkdir(parents=True, exist_ok=True)
            with open(esc_path, "a", encoding="utf-8") as fh:
                fh.write(f"\n## adopt escalation ({_now_iso()}) — run {state.get('run_id')}\n")
                for e in escalations:
                    fh.write(f"- **{e['slice']}**: {e['reason']}\n")
            report["escalations_written"] = str(esc_path)
        return 2, report

    # --- adoptable. Optionally stamp provenance into run-state (idempotent; git already reconciled).
    report["verdict"] = "adoptable"
    if a.write_back:
        state["subagents"] = str(manifest_path.relative_to(repo)) if str(manifest_path).startswith(str(repo)) \
            else str(manifest_path)
        state["adopted_from"] = {
            "adopted_at": _now_iso(),
            "from_status": prior_status,
            "by_session": a.session_id or "unknown",
            "prior_run_id": state.get("run_id"),
        }
        tmp = rs_path.with_suffix(".adopt.tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(rs_path)
        report["run_state_stamped"] = str(rs_path)
    return 0, report


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Parallax v0.38 adopt reconciler (git is the truth).")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--prefix", default="feature/", help="branch prefix (codex.toml [git] branch_prefix)")
    ap.add_argument("--run-state", default=None, help="default: <repo>/.parallax/<slug>/run-state.json")
    ap.add_argument("--manifest", default=None, help="default: <repo>/.parallax/<slug>/subagents.json")
    ap.add_argument("--escalations", default=None, help="default: <repo>/.parallax/<slug>/escalations.md")
    ap.add_argument("--session-id", dest="session_id", default=None,
                    help="the ADOPTING session's id (recorded in adopted_from)")
    ap.add_argument("--now", default=None, help="ISO override for the lease check (testing/determinism)")
    ap.add_argument("--write-back", action="store_true",
                    help="persist the escalation / adopted_from provenance (default: report only)")
    a = ap.parse_args(argv)
    code, detail = adopt(a)
    print(json.dumps(detail))
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
