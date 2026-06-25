# Safe-completion benchmark (AC9) — live validation plan

This is the **empirical** acceptance gate for v0.31 safe completion
(DESIGN_v0.31_safe_completion.md §18 end-to-end regressions + §19 AC9). It proves
the whole loop end-to-end: a real run **parks** on a confirmed spec-gap, a human
**decides**, a **new contract generation** is built blind and verified, and the
feature reaches `complete` — with **no false-green** and **no regression on clear
tasks**.

## Why this is not in `tests/run.sh`
The unit harness (`tests/run.sh`, currently 73 checks) locks the **mechanical and
contract** pieces: the queue/receipt/feature-state writes and their fail-closed set
(`resolution.py`), the append-only restart + atomic CAS (`generation-restart.sh`),
the generation-aware epic gate (`epic-gate.py`), the migration, and the presence of
every command/role wiring. What it **cannot** exercise is the part that needs live
models: two blind tracks actually building from a real spec, a real cross-model
verifier judging, and a human decision driving a real rebuild. So AC9 runs on the
**`parallax-bench/` harness against a live pipeline**, not in CI.

> **Status: NOT YET RUN — recorded as a verification gap, not a pass.** Run it with a
> real `.parallax/codex.toml` verifier configured (`pip install jsonschema`, `codex`
> and/or `gemini` CLIs available) before tagging v0.31.0 as empirically validated.

## Target set (≥15 resolution cycles)
- **2 known parked benchmark tasks** × **3 trials** each (the tasks that historically
  produced a correct `safe-resolution` in the v0.30 confirmatory benchmark).
- **≥3 fresh spec-gap tasks** × **3 trials** each (new ambiguities not seen before).
- Total **≥15 resolution cycles**.

## Metrics & thresholds (all must hold)
- After a **valid human decision**: `safe_completion = 1.0` (every decided feature
  reaches `complete` and the hidden/real validation is green).
- `false_green = 0` (no feature reaches `complete` against the *old* contract, and no
  stale-generation ledger ever certifies the new one — the epic gate must `hold` it).
- **Without** a decision: `completion = 0` and the run stays **safely parked**
  (`needs-resolution`), starting no build.
- The **clear-task regression suite** (no spec-gap) is **unchanged** — safe completion
  must not perturb a feature that never needed resolving.

## Named end-to-end cases (§18)
- **`cfg-migrate`** — park on an unknown default `retries`; the human chooses `3`; the
  new blind run completes hidden acceptance 100%.
- **`search-box`** — park on stale responses; the human gives a drop-stale rule; the
  new run completes hidden acceptance 100%.
- **No decision** keeps `needs-resolution` and starts no build.
- **A decision that leaves a new ambiguity** is parked again by the verifier (the new
  generation is *not* auto-accepted by the original token).
- **`rescope`** removes a behaviour from acceptance **only** when the contract
  explicitly changes — it is never a waiver of an existing check.

## How to run
1. In a benchmark repo with a real toolchain and a configured `.parallax/codex.toml`,
   run each task through `/parallax:auto` (or `/parallax:spec` → `/parallax:run`) until
   it parks at `needs-resolution`.
2. Supply the decision via `/parallax:resolve <slug>` (interactive) or
   `--from-file <decision.json>` (prepared decision); repeat the exact one-time token.
3. Let the new generation rebuild via `/parallax:run`, and check the **hidden**
   acceptance suite (held out from the blind tracks) is green.
4. Record one row per cycle below.

## Results (fill on a live run)
| task | trial | parked reason | decision | gen | safe_completion | false_green | hidden acceptance |
|------|-------|---------------|----------|-----|-----------------|-------------|-------------------|
| cfg-migrate | 1 | spec-gap (retries default) | choose-option=3 | 1→2 | — | — | — |
| … | | | | | | | |

A cycle **fails** AC9 if it reaches `complete` against the old contract, if a
stale-generation ledger passes the epic gate, if a no-decision run starts a build, or
if a clear task's outcome changed.
