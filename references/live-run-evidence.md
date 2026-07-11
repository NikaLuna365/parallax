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
| `subagents.json` (v0.38) | `assets/subagents.schema.json` | per-slug **dispatched-subagent manifest**: one entry per `(slice, role)` — `branch`, `wave_base`, `dispatched_at`, `session_id`, `mode` (foreground/background), `status` (dispatched/reported/reaped/stale), `reported_commit?`. Written at dispatch, committed to `feature/<slug>`; the record `--adopt` reconstructs in-flight background tracks from |
| `handoff.md` (v0.38) | *(rendered, not schema'd)* | machine-generated session handoff — integrated slices, in-flight tracks (branch/commit/status), owed verifications, escalations, the exact `--adopt` command; deterministic, no operator free-text. Replaces the hand-written `RUN-HANDOFF.md` |

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

## Multi-session continuity (v0.38 — `subagents.json` + generated `handoff.md`)
The v0.37.4 RUN2 soak exposed the gap: a build that outlives one session **uncleanly** (context death,
in-flight background tracks) left no machine record of what was dispatched or where it landed, so the
operator hand-wrote `RUN-HANDOFF.md` and reconstructed branch tips by hand. v0.38 makes both the record
and the handoff **first-class artifacts**. `subagents.json` (F8) is written **at dispatch** through the
deterministic `scripts/subagent-manifest.py` (schema-validated, fail-closed, one entry per track,
committed on `feature/<slug>` so it survives a session boundary / cloud clone) and reconciled against
live git on adopt — a vanished branch is `stale`, an ahead-of-`wave_base` background branch is `reaped`
with its commit read off git (the notification that never crossed the boundary, replaced by reading
git). `handoff.md` is **rendered**, not authored, by `scripts/render-handoff.py` from run-state +
`subagents.json` + `events.jsonl` — deterministic, with the exact `/parallax:run --adopt <slug>` command
and no free-text field a human must fill. Both are auditability/recovery artifacts, **not** a benchmark:
they record what was dispatched and reconstruct the truth git-first; they never assert a slice is
verified — that stays with the arbiter/verifier receipts, which adopt refuses to fabricate.

## Making the evidence fire on the box (v0.39 — hand-driven done-gate + telemetry regeneration)
The v0.38.1 monorepo soak found the evidence trail was **written by the skill flow but skipped on the
hand path**: RUN-B/RUN-C had no `run-evidence.json` / `events.jsonl` at all, and RUN-A's
`run-evidence.json` stayed frozen at a spec-phase `0.36.1`/`frozen-spec` after a v0.38.1 build. v0.39
makes the evidence reachable and current at the **done-gate**, on both the skill AND hand path:
`scripts/finalize-handdriven.py` (the `--finalize` done-gate entry) emits the adopt-critical receipts
(`slice_dispatched` + `arbiter_green`) into `events.jsonl` and runs `evidence-event.py audit-slice`
before a hand-integrated slice may be treated as done (fail-closed E1); and `evidence-event.py
update-run --restamp-version` re-stamps `run-evidence.json` `plugin.version` to the LIVE plugin version
and moves `status` off `frozen-spec` at every done-gate, so the evidence reflects the plugin that
actually built the slice — not the freeze-phase snapshot (#11). The evidence remains auditability, not
a benchmark: it records what happened and never asserts a slice is verified (that stays with the
arbiter/verifier receipts the hand-driven finalize gates through `merge-ledger`/`triage`). The
companion push guard (`scripts/push-guard.sh`) is a git-integrity check, not evidence — see
`references/runtime-governance.md`.

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
