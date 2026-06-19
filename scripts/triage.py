#!/usr/bin/env python3
"""Parallax review-finding triage — the MECHANICAL half of the hybrid review policy.

Given a review ledger (the cross-model verifier's findings + their lifecycle) and the
`[review]` policy, decide deterministically whether a slice may go GREEN, must BLOCK
(route a fix and re-review), or must ESCALATE (park for a human). Severity-gating and the
always-block kinds are enforced here in code so the harness can unit-test them; the
*no-anchoring* review protocol (regression-recheck, fresh scan, spec_ref required) is a
prompt directive to the provider and lives in skills/role-codex-judge — it is NOT testable
here, and we say so honestly.

Hybrid policy (chosen by the user, v0.20.0):
  - A finding is LIVE iff status in {open, regressed}. {fixed} is settled.
  - For each LIVE finding (severity s, kind k, optional Claude rebuttal r):
        always_block(k or functional_repro)             -> BLOCK   (cannot be waived, ever)
        s in block_severities  and r set                -> CONTEST (Claude disputes; ESCALATES, never auto-green)
        s in block_severities  and r unset              -> BLOCK
        s in advisory_severities and not always_block    -> ADVISORY (recorded, does NOT block green)
        (any other / unknown severity)                  -> BLOCK   (conservative)
  - Slice decision:
        blockers or contests present:
            rounds_used >= max_rounds  -> "escalate"   (stop looping — park)
            elif blockers              -> "block"       (route fix, spend another round)
            else (only contests)       -> "escalate"
        else                           -> "green"       (advisories may remain)

Usage:
    triage.py LEDGER.json [POLICY.json]      # POLICY optional; ledger may embed "policy"
    triage.py - < LEDGER.json                # ledger on stdin
Exit code: 0 green, 1 block, 2 escalate, 3 bad input. Prints a JSON decision to stdout.
"""
import json, sys

DEFAULT_POLICY = {
    "max_rounds": 2,
    "resume_codex_session": False,
    "recheck_fixed": True,
    "block_severities": ["medium", "high"],
    "advisory_severities": ["low"],
    "always_block_kinds": ["safety", "anti-cheat", "spec-gap"],
}
VALID_REBUTTALS = {"duplicate", "not-reproducible", "contradicts-spec", "out-of-scope"}


def disposition(f, policy):
    """Return one of BLOCK | CONTEST | ADVISORY | SETTLED for a single finding."""
    if f.get("status") not in ("open", "regressed"):
        return "SETTLED"
    kind = f.get("kind")
    sev = f.get("severity")
    always = kind in policy["always_block_kinds"] or bool(f.get("functional_repro"))
    if always:
        return "BLOCK"                       # safety / anti-cheat / spec-gap / reproducible functional — never waivable
    if sev in policy["block_severities"]:
        reb = f.get("claude_rebuttal") or {}
        if reb.get("reason") in VALID_REBUTTALS:
            return "CONTEST"                 # disputed at blocking severity -> escalate, never auto-green
        return "BLOCK"
    if sev in policy["advisory_severities"]:
        return "ADVISORY"                    # low + non-critical -> recorded, non-blocking
    return "BLOCK"                           # unknown severity -> conservative


def triage(ledger, policy=None):
    pol = dict(DEFAULT_POLICY)
    pol.update(ledger.get("policy") or {})
    if policy:
        pol.update(policy)
    rounds_used = int(ledger.get("rounds_used", 0))
    blockers, contests, advisories = [], [], []
    for f in ledger.get("findings", []):
        d = disposition(f, pol)
        if d == "BLOCK":      blockers.append(f.get("id"))
        elif d == "CONTEST":  contests.append(f.get("id"))
        elif d == "ADVISORY": advisories.append(f.get("id"))
    if blockers or contests:
        if rounds_used >= pol["max_rounds"]:
            decision = "escalate"            # budget spent — park instead of looping forever
        elif blockers:
            decision = "block"
        else:
            decision = "escalate"
    else:
        decision = "green"
    return {
        "decision": decision,
        "blockers": blockers,
        "contests": contests,
        "advisories": advisories,
        "rounds_used": rounds_used,
        "max_rounds": pol["max_rounds"],
    }


def main(argv):
    if not argv:
        print(__doc__); return 3
    src = sys.stdin.read() if argv[0] == "-" else open(argv[0]).read()
    try:
        ledger = json.loads(src)
    except Exception as e:
        print(json.dumps({"decision": "escalate", "error": f"bad ledger: {e}"})); return 3
    policy = json.load(open(argv[1])) if len(argv) > 1 else None
    out = triage(ledger, policy)
    print(json.dumps(out))
    return {"green": 0, "block": 1, "escalate": 2}.get(out["decision"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
