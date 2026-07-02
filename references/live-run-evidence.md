# Live-run evidence (v0.36)

From v0.36, every `/parallax:spec`, `/parallax:run`, `/parallax:auto`, and `/parallax:resolve` leaves
**first-class, structured evidence** under `.parallax/<slug>/evidence/` so a real run is auditable from
its own artifacts — not reconstructed after the fact from a Claude transcript.

## What these artifacts are — and are NOT
- They are **auditability evidence** of what a run did: which command, which plugin version, which
  capabilities, which lifecycle events, which live checks, which defect loops.
- They are **not** a benchmark result, **not** an external calibration, and **not** a hidden oracle.
  Public tests and live e2e in this evidence are *structured observations*, never proof that a held-out
  acceptance oracle passed.
- A Claude **transcript/session path** is recorded only as **auxiliary `provenance`**, never as primary
  proof. Transcript scraping is not the evidence mechanism.

## The files
| file | schema | what it holds |
|------|--------|---------------|
| `evidence/run-evidence.json` | `assets/run-evidence.schema.json` | one per run: plugin (name + **version**, stamped from the manifest), run (id/slug/command_entry/status), repo, artifact paths, capabilities exercised, evidence limits, provenance |
| `evidence/events.jsonl` | `assets/run-evidence-event.schema.json` | **append-only** timeline: one JSON event per line (`intake_received`, `spec_frozen`, `slice_dispatched`, `arbiter_green`, `verifier_pass`, `defect_found`, `run_completed`, …) with actor + `artifact_paths` |
| `evidence/e2e-checks.jsonl` (optional) | `assets/e2e-check.schema.json` | live e2e checks: command, result, exit code, output paths, observed claims. A `result=pass` must carry a real command or be explicitly `manual` with a note |
| `evidence/defect-loop.jsonl` (optional) | `assets/defect-loop.schema.json` | the GPI A12 pattern: a live defect → `source_evidence` → spec/assumption change → test-writer RED → blind-coder fix → result → re-verification |

Missing data is `null`/absent per schema, **never silently invented**. A summary is not proof when a
file/log exists — put its path in `artifact_paths`.

## Run-phase coverage (v0.37.3 F5)
Three audited production runs showed `events.jsonl` stopping at `spec_frozen` and `run.status`
stuck at `frozen-spec` for the whole build — the v0.36 wiring existed for Phase 1 only as prose for
Phase 2-5. From v0.37.3 the build phase is covered **through a deterministic helper**,
`scripts/evidence-event.py`: `append` schema-validates each event *before* writing (fail closed,
append-only, run_id/slug cross-checked against `run-evidence.json`), and `update-run` moves
`run.status` (`frozen-spec → running → complete`, or `needs-resolution`) under full-document
validation. The event schema adds the build-phase types the audit found missing —
`arbiter_iteration_started/finished`, `codex_round_started/finished`, `slice_green`, `pr_opened`,
`pr_merged`, `session_handoff`, `feature_merged` — additively (all v0.36 types unchanged).
`commands/run.md` invokes the helper at every Phase 2-5 transition: slice dispatch, track done-gates,
each arbiter iteration, each verifier round (recording `human-authorized` vs `self-continued`
rounds as distinct facts), slice green, pauses/parks, the terminal `run_completed`, and
feature-merged/PR events when known. Still auditability only: structured observations of what the
run did — not a benchmark, and `evidence_limits` must stay factual (never assert a transcript is
"unavailable" when it merely wasn't captured — record the real path when it exists).

## Why this release (the GPI lesson, in the abstract)
A recent real Parallax run demonstrated the method end-to-end — intake/spec, Architecture Fitness,
blind TDD tracks, a live e2e, and a post-e2e **trust defect** that was turned into a spec assumption,
blind tests, a code fix, and a re-e2e (a textbook defect loop). But it left **no first-class Parallax
evidence**: no local run-state, no receipts, no plugin-version stamp in the run artifacts, no structured
event ledger, and nothing harness-v2-compatible — so its behaviour had to be reconstructed from the
transcript. v0.36 closes that gap for **future** runs. The case is **design input only**; it is **not**
shipped as a benchmark result.

## Mapping to harness v2 (`harness-record.candidate.json`)
A run may emit `.parallax/<slug>/evidence/harness-record.candidate.json` as a **candidate** harness-v2
record (`bench/harness_v2/record.schema.json`) — **never** a benchmark result. Rules:
- it is a *candidate* for later review/aggregation, not a scored result;
- its `reviewer_notes` must point back to `run-evidence.json`, `events.jsonl`, and (when present)
  `e2e-checks.jsonl` / `defect-loop.jsonl`;
- if there is **no held-out hidden oracle**, `functional.hidden_oracle_pass` is **`null`** — never
  inferred from public tests or a live e2e;
- if the record is reconstructed from a transcript or by hand, set `evidence_source =
  "transcript-derived"` and do **not** classify it as controlled benchmark evidence.

In short: this is the audit trail a run *should* leave. Turning it into measured quality still requires
the harness-v2 path with a real hidden oracle and raw records — which is the v0.36 benchmark, not this.
