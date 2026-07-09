#!/usr/bin/env bash
# v0.38 5.1 / TRIAGE gates A1+A2 — EXECUTES pre-freeze-budget.py freeze-check + mode binding.
# Closes the RUN1 live finding: an `--autonomous --from-doc` run froze through the INTERACTIVE
# human-OK branch with closure.status=open after 3x concerns. Locks:
#   A1a. autonomous + closure=open  -> freeze-check REFUSES (exit 2) — a simulated human OK
#        is not an input: the check reads only artifacts, so "Nikolai present" changes nothing;
#   A1b. autonomous + closure=independent-pass -> freeze-check ALLOWS (path autonomous-independent-pass);
#   A1c. interactive + human-OK + closure open -> ALLOWED (path interactive-human-ok, unchanged);
#   A1d. autonomous with NO pre-freeze state at all (verifier never ran / on_missing=warn)
#        -> REFUSED — warn does not license an autonomous freeze;
#   A2a. grant-one under --mode autonomous -> refused outright (autonomous never self-grants
#        a human round);
#   A2b. a grant HAND-EDITED into an autonomous state -> the state fails on the next read;
#   M1.  mode is pinned at init: an autonomous-inited state called with --mode interactive
#        (the relabel that happened live) -> GateError, exit 2 — and vice versa;
#   M2.  a legacy state without `mode` is schema-invalid -> escalate (fail closed), never a
#        silent default to interactive.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; cd "$PLUGIN"
PF(){ python3 scripts/pre-freeze-budget.py "$@"; }
fail(){ echo "FAIL: $1"; exit 1; }
python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo "t_freeze_mode_binding SKIP (jsonschema not installed — the gate itself fails closed without it)"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp assets/codex/codex.toml.example "$T/codex.toml"
printf 'candidate spec\n'       > "$T/spec.md"
printf 'candidate slices\n'     > "$T/slices.md"
printf 'candidate validation\n' > "$T/validation.md"
printf '{"slug":"demo","slices":["S1"]}\n' > "$T/slices.lock"
CF=(--contract-file "$T/spec.md" --contract-file "$T/slices.md" --contract-file "$T/validation.md" --contract-file "$T/slices.lock")
CONCERNS='{"verdict":"concerns","findings":[{"severity":"high","kind":"spec-gap","where":"B1","detail":"observable divergence"}]}'
PASS='{"verdict":"pass","findings":[]}'

# --- A1d) autonomous, NO state at all -> refuse
A="$T/a"; mkdir -p "$A"; SA="$A/pre-freeze-state.json"
PF freeze-check "$SA" --policy "$T/codex.toml" --slug demo --mode autonomous >/tmp/parallax_fmb1; RC=$?
[ "$RC" -eq 2 ] || fail "A1d: autonomous freeze with no verifier state was allowed (rc=$RC)"
grep -qF 'independent-pass' /tmp/parallax_fmb1 || fail "A1d: refuse reason missing: $(cat /tmp/parallax_fmb1)"

# --- A1a) autonomous + concerns round (closure open) -> refuse, regardless of any human at the console
printf '%s\n' "$CONCERNS" > "$A/r1.json"
PF record "$SA" "$A/r1.json" --policy "$T/codex.toml" --slug demo --mode autonomous --provider codex "${CF[@]}" >/dev/null || fail "A1a: autonomous concerns record failed"
PF freeze-check "$SA" --policy "$T/codex.toml" --slug demo --mode autonomous >/tmp/parallax_fmb2; RC=$?
[ "$RC" -eq 2 ] || fail "A1a: autonomous + closure=open freeze was allowed (rc=$RC)"
grep -qF 'interactive human-OK branch is unreachable' /tmp/parallax_fmb2 || fail "A1a: wrong refuse reason: $(cat /tmp/parallax_fmb2)"

# --- M1) the RUN1 relabel: the same autonomous state, now claimed interactive -> refused
PF freeze-check "$SA" --policy "$T/codex.toml" --slug demo --mode interactive >/tmp/parallax_fmb3; RC=$?
[ "$RC" -eq 2 ] || fail "M1: autonomous state relabeled interactive was accepted (rc=$RC)"
grep -qF 'cannot be relabeled' /tmp/parallax_fmb3 || fail "M1: wrong relabel error: $(cat /tmp/parallax_fmb3)"

# --- A2a) grant-one refuses outright in autonomous mode (fresh and at-cap alike)
printf '%s\n' "$CONCERNS" > "$A/r2.json"
PF record "$SA" "$A/r2.json" --policy "$T/codex.toml" --slug demo --mode autonomous --provider codex "${CF[@]}" >/dev/null; true
PF grant-one "$SA" --policy "$T/codex.toml" --slug demo --mode autonomous --token 'PARALLAX-GRANT:demo:pre-freeze-round-3' >/tmp/parallax_fmb4; RC=$?
[ "$RC" -eq 2 ] || fail "A2a: grant-one in autonomous mode was accepted (rc=$RC)"
grep -qF 'interactive affordance' /tmp/parallax_fmb4 || fail "A2a: wrong grant refusal: $(cat /tmp/parallax_fmb4)"

# --- A2b) a grant hand-edited INTO the autonomous state fails on the very next read
python3 - "$SA" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["grants"]=[{"round":3,"token":"PARALLAX-GRANT:demo:pre-freeze-round-3","approved_by":"human","approved_at":"2026-07-09T00:00:00Z"}]
json.dump(s,open(p,"w"))
PY
PF check "$SA" --policy "$T/codex.toml" --slug demo --mode autonomous >/tmp/parallax_fmb5; RC=$?
[ "$RC" -eq 2 ] || fail "A2b: hand-edited grant in autonomous state was accepted (rc=$RC)"
grep -qF 'can never' /tmp/parallax_fmb5 || fail "A2b: wrong rejection: $(cat /tmp/parallax_fmb5)"
python3 - "$SA" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["grants"]=[]; json.dump(s,open(p,"w"))
PY

# --- A1b) autonomous + a real verifier PASS -> allowed, path autonomous-independent-pass
B="$T/b"; mkdir -p "$B"; SB="$B/pre-freeze-state.json"
printf '%s\n' "$PASS" > "$B/r1.json"
PF record "$SB" "$B/r1.json" --policy "$T/codex.toml" --slug demo --mode autonomous --provider codex "${CF[@]}" >/dev/null || fail "A1b: autonomous pass record failed"
PF freeze-check "$SB" --policy "$T/codex.toml" --slug demo --mode autonomous >/tmp/parallax_fmb6 || fail "A1b: autonomous + independent-pass freeze was refused: $(cat /tmp/parallax_fmb6)"
grep -qF '"freeze_path": "autonomous-independent-pass"' /tmp/parallax_fmb6 || fail "A1b: wrong freeze path: $(cat /tmp/parallax_fmb6)"

# --- A1c) interactive + closure open -> allowed through the human-OK branch (unchanged behavior)
C="$T/c"; mkdir -p "$C"; SC="$C/pre-freeze-state.json"
printf '%s\n' "$CONCERNS" > "$C/r1.json"
PF record "$SC" "$C/r1.json" --policy "$T/codex.toml" --slug demo --mode interactive --provider codex "${CF[@]}" >/dev/null || fail "A1c: interactive record failed"
PF freeze-check "$SC" --policy "$T/codex.toml" --slug demo --mode interactive >/tmp/parallax_fmb7 || fail "A1c: interactive human-OK freeze branch was refused: $(cat /tmp/parallax_fmb7)"
grep -qF '"freeze_path": "interactive-human-ok"' /tmp/parallax_fmb7 || fail "A1c: wrong freeze path: $(cat /tmp/parallax_fmb7)"
# interactive with NO state -> also the human-OK branch (verifier not configured)
PF freeze-check "$T/absent-state.json" --policy "$T/codex.toml" --slug demo --mode interactive >/dev/null || fail "A1c2: interactive freeze with no state refused"

# --- M1b) the reverse relabel: interactive state claimed autonomous -> refused
PF freeze-check "$SC" --policy "$T/codex.toml" --slug demo --mode autonomous >/dev/null; RC=$?
[ "$RC" -eq 2 ] || fail "M1b: interactive state relabeled autonomous was accepted (rc=$RC)"

# --- M2) a legacy state without `mode` is schema-invalid -> escalate, never a silent default
python3 - "$SC" <<'PY'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s.pop("mode"); json.dump(s,open(p,"w"))
PY
PF check "$SC" --policy "$T/codex.toml" --slug demo --mode interactive >/tmp/parallax_fmb8; RC=$?
[ "$RC" -eq 2 ] || fail "M2: mode-less legacy state was accepted (rc=$RC)"
grep -qiF 'schema validation failed' /tmp/parallax_fmb8 || fail "M2: not schema-rejected: $(cat /tmp/parallax_fmb8)"

echo "t_freeze_mode_binding OK"
