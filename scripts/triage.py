#!/usr/bin/env python3
"""Parallax review-finding triage — the MECHANICAL, FAIL-CLOSED disposition gate.

Decides green | block | escalate for a slice from its review ledger. Hardened in v0.21.0
against producer self-certification (the whole point of Parallax: the model that produced
the work must not be able to certify itself):

  * POLICY COMES ONLY FROM TRUSTED CONFIG. The `[review]` policy is read from the
    .parallax/codex.toml you pass via --policy — NEVER from the ledger (the ledger is written
    by the orchestrating Claude; trusting a ledger-supplied policy let a crafted ledger set
    always_block_kinds=[] and turn a high `safety` finding into green). Any `policy` key in
    the ledger is ignored. Missing/unparseable config => SAFE STRICT DEFAULTS (fail closed).

  * "fixed" IS NOT SELF-ASSERTABLE. A finding counts as settled only if it was verified by the
    independent model AND against the *current* tree: status=="fixed" AND verified_by=="codex"
    AND last_verified_diff == --current-diff. A `fixed` that Claude merely stamped (no
    verified_by, or a stale diff) is treated as LIVE and still blocks.

  * FAIL CLOSED ON A BAD LEDGER. If jsonschema is available and the ledger doesn't validate
    against assets/codex/review-ledger.schema.json, the decision is `escalate`, never green.

Usage:
    triage.py LEDGER.json --policy .parallax/codex.toml --current-diff <sha> [--schema PATH]
    triage.py - --policy ... --current-diff ...        # ledger on stdin
Exit code: 0 green, 1 block, 2 escalate, 3 bad input. Prints a JSON decision to stdout.
"""
import argparse, hashlib, json, os, sys

# SAFE STRICT DEFAULTS — used verbatim when --policy is missing/unreadable (fail closed).
DEFAULT_POLICY = {
    "max_rounds": 2,
    "block_severities": ["medium", "high"],
    "advisory_severities": ["low"],
    "always_block_kinds": ["safety", "anti-cheat", "spec-gap"],
}
VALID_REBUTTALS = {"duplicate", "not-reproducible", "contradicts-spec", "out-of-scope"}
_POLICY_KEYS = ("max_rounds", "block_severities", "advisory_severities", "always_block_kinds")


def load_policy(toml_path):
    """Policy from the TRUSTED toml only. Never from the ledger. Fail-closed to strict defaults."""
    pol = dict(DEFAULT_POLICY)
    if not toml_path or not os.path.exists(toml_path):
        return pol, "no-config:strict-defaults"
    try:
        import tomllib
        review = tomllib.load(open(toml_path, "rb")).get("review", {})
        for k in _POLICY_KEYS:
            if k in review:
                pol[k] = review[k]
        return pol, None
    except Exception as e:
        return dict(DEFAULT_POLICY), f"config-parse-error:strict-defaults ({e})"


def is_settled(f, current_diff):
    """A finding is settled ONLY if the INDEPENDENT model verified the fix against the CURRENT tree."""
    return (
        f.get("status") == "fixed"
        and f.get("verified_by") == "codex"
        and current_diff is not None
        and f.get("last_verified_diff") == current_diff
    )


def disposition(f, policy, current_diff):
    if is_settled(f, current_diff):
        return "SETTLED"                      # codex-verified fix against the current diff
    # Everything else is LIVE — including a `fixed` that lacks codex verification / a current diff.
    kind, sev = f.get("kind"), f.get("severity")
    if kind in policy["always_block_kinds"] or bool(f.get("functional_repro")):
        return "BLOCK"                        # safety / anti-cheat / spec-gap / reproducible functional — never waivable
    if sev in policy["block_severities"]:
        reb = f.get("claude_rebuttal") or {}
        return "CONTEST" if reb.get("reason") in VALID_REBUTTALS else "BLOCK"
    if sev in policy["advisory_severities"]:
        return "ADVISORY"
    return "BLOCK"                            # unknown severity -> conservative


def validate_ledger(ledger, schema_path):
    """Fail-closed structural check. Returns an error string, or None if valid / unavailable."""
    try:
        import jsonschema
    except ImportError:
        return None                           # can't validate here; the harness does it where jsonschema exists
    if not schema_path or not os.path.exists(schema_path):
        return None
    try:
        jsonschema.validate(ledger, json.load(open(schema_path)))
        return None
    except Exception as e:
        return f"ledger-schema-invalid: {getattr(e, 'message', e)}"


def triage(ledger, policy, current_diff):
    blockers, contests, advisories = [], [], []
    for f in ledger.get("findings", []):
        d = disposition(f, policy, current_diff)
        if d == "BLOCK":      blockers.append(f.get("id"))
        elif d == "CONTEST":  contests.append(f.get("id"))
        elif d == "ADVISORY": advisories.append(f.get("id"))
    rounds_used = int(ledger.get("rounds_used", 0))
    if blockers or contests:
        if rounds_used >= policy["max_rounds"]:
            decision = "escalate"
        elif blockers:
            decision = "block"
        else:
            decision = "escalate"
    else:
        decision = "green"
    return {"decision": decision, "blockers": blockers, "contests": contests,
            "advisories": advisories, "rounds_used": rounds_used, "max_rounds": policy["max_rounds"]}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("ledger")
    ap.add_argument("--policy", help="path to the TRUSTED .parallax/codex.toml")
    ap.add_argument("--current-diff", dest="current_diff", help="SHA of the assembled tree under review")
    ap.add_argument("--schema", default="assets/codex/review-ledger.schema.json")
    a = ap.parse_args(argv)
    try:
        src = sys.stdin.read() if a.ledger == "-" else open(a.ledger).read()
        ledger = json.loads(src)
    except Exception as e:
        print(json.dumps({"decision": "escalate", "error": f"bad ledger: {e}"})); return 3
    schema_err = validate_ledger(ledger, a.schema)
    if schema_err:
        print(json.dumps({"decision": "escalate", "error": schema_err})); return 2
    policy, note = load_policy(a.policy)
    out = triage(ledger, policy, a.current_diff)
    if note:
        out["policy_note"] = note
    print(json.dumps(out))
    return {"green": 0, "block": 1, "escalate": 2}.get(out["decision"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
