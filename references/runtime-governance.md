# Runtime governance hardening (v0.37)

v0.37 takes Parallax rules that were already in prose — the ones the v0.36.1 live runs
proved valuable — and makes them **harder to skip at runtime**. It is a *mechanical
enforcement* release: no new public command, no benchmark or quality claim, and every
v0.31–v0.36.1 boundary preserved. This note records, honestly, what is **mechanical**
(a script/schema the harness executes) versus **directive** (a prompt-contract obligation
the harness can only check is *present*, not that a live model obeyed it).

## The four P0 gates

### P0.1 — Blindness isolation guard (`scripts/blindfold-guard.py`)
- **Mechanical:** given a track worktree, the guard fails closed (exit 2) if the *test* side
  has tracked implementation source or compiled build output (`dist/`, `build/`, …), or the
  *code* side has tracked test files. `/parallax:run` runs it before dispatching each blind
  track and again before its done-gate, **per wave**. Harness: `tests/t_blindfold.sh`.
- **Directive:** the redispatch envelope (arbiter→track feedback carries only natural-language
  faults anchored to spec refs, never selectors / `file:line` / exports / markup), the arbiter's
  cross-worktree **contamination** anti-cheat class, and the test-writer's brownfield-baseline
  rule (never read impl/compiled output for an expected value).

### P0.2 — Standalone finalize gate (`scripts/finalize-gate.py`)
- **Mechanical:** before feature push / epic advance the gate reads the committed ref and holds
  unless every slice carries a committed, schema-valid **green arbiter receipt**
  (`assets/arbiter-receipt.schema.json`), no slice is `green-unverified`, the required evidence
  artifacts are committed, and the run-state is `complete` + fresh; it then delegates the deep
  per-slice verifier / contract-hash / verified-tree / frozen-slice-set checks to the existing
  `scripts/epic-gate.py`. Harness: `tests/t_finalize_gate.sh` (+ the existing `tests/t_epic_gate.sh`).
- **Directive:** verifier-limited continuation (build may reach `green-unverified` but must not
  integrate/finalize until verifier debt is drained, reusing `paused-on-limit` + `paused.service=codex`)
  and **loud no-codex degradation** for trust / anti-cheat / money / PII / security / safety specs.
  The receipt's *presence + identity + green verdict* is mechanical; that the arbiter was a genuinely
  independent dispatch is a role obligation the schema cannot prove.
- **Freshness (v0.37.1, mechanical evidence binding — NOT wall-clock recency).** v0.37.0 treated a
  "fresh" run-state as merely a non-empty `updated_at`. v0.37.1 binds freshness to a terminal
  `completion` receipt on the run-state (`assets/run-state.schema.json`, required once `status==complete`):
  `finalize-gate.py` fails closed unless the run-state is schema-valid; `updated_at` and
  `completion.completed_at` parse as ISO-8601; `completion.run_id`/`verified_tree` match the run-state and
  `verified_tree` equals the recomputed `code-tree-hash`; the committed `run-evidence.json` validates and
  its `run.run_id`/`slug`/`status` agree; every `events.jsonl` line validates and a same-run
  `run_completed` event exists; and the **sha256** of the committed `run-evidence.json` / `events.jsonl`
  equal `completion.*_sha256`. This deliberately avoids a wall-clock max-age rule (which would make long
  autonomous runs flaky) and avoids a self-referential commit-oid; it proves the *terminal bundle is
  internally consistent*, not that it is recent. Harness: the `[finalize_freshness]` section.

### P0.3 — Whole-feature invariant sweep (`scripts/feature-sweep.py`)
- **Mechanical:** against the integrated tree the sweep executes the invariant classes the spec
  declared in `.parallax/<slug>/invariants.json` (`assets/feature-invariants.schema.json`):
  forbidden patterns (PII/trust/anti-cheat/money) reaching shipped code, a shared field with no
  live consumer (dead seam), and a mock-only I/O slice with neither an integration check nor an
  explicit stamp. A violation (exit 2) or a missing manifest (exit 3) blocks completion. Harness:
  `tests/t_feature_sweep.sh` — a per-slice-green tree that still serializes a PII field is caught.
- **Directive:** the `/parallax:spec` **Prohibition Reconciliation** substep (3.6) that records the
  manifest, and the arbiter's per-field **live-consumer proof** rule. The sweep is a concrete-invariant
  gate, deliberately **not** a broad style/architecture review.

### P0.4 — Auditable frozen-contract tightening (`scripts/contract-amend.py`)
- **Mechanical:** `verify` accepts post-freeze contract bytes only when a continuous `prev→new`
  hash chain of valid amendment records (`assets/contract-amendment.schema.json` — kind
  `mechanical-tightening`, evidence present, pre-freeze pass/low-notes, all six propagation flags
  true) connects the frozen contract hash to the current bytes; any post-freeze change with no such
  chain is rejected (exit 2). Harness: `tests/t_contract_amend.sh`.
- **Directive:** the rule that a *determinate* mechanical under-scope uses this path while genuine
  ambiguity / a product fork still goes through `/parallax:resolve`.

## P1 (production hardening, as far as P0 allowed)
- **Done mechanically in this release:** finalize requires committed evidence
  (`.parallax/<slug>/evidence/{run-evidence.json,events.jsonl}`) and a fresh run-state; the existing
  `run-state.lock` lease already prevents two sessions advancing the same slug.
- **Directive:** resume reconciles already-integrated slices and skips them.
- **Deferred to a follow-up `v0.37.1` plan (not weakening P0):** a full `--resume` **adopt** path
  that reconstructs canonical run-state from an in-progress branch (derive per-slice tips, recompute
  `contract_hash` / `verified_tree`, reconcile the integrated set, label unverified honestly), and the
  CI/lint-parity + frontend-DOM-seam mechanics. v0.37 adds the prompt-contract obligations for these;
  the mechanical adopt reconstructor is the v0.37.1 scope.

## v0.37.3 — live-run reliability hardening of the gates above
Three post-v0.37.2 production monorepo runs (`references/live-run-audit-findings.md` — the source
record; a findings list, never a benchmark) showed where the v0.37 mechanics false-positive or
under-fire on a real repo. v0.37.3 hardens them without weakening any boundary:

- **P0.1 extension (mechanical).** `blindfold-guard.py` gains the slice-scoped monorepo mode:
  `--scope-manifest` (schema `assets/blindfold-scope.schema.json`) names the slice's OWN
  new/changed protected paths — always fail-closed on the opposite track, before any allowlist —
  plus package-specific `dependency_allow_globs` the test side may keep for import resolution; in
  scoped mode the existing base tree is visible by design while the slice's own impl and its own
  package `dist/` still fail closed. A whole-tree glob is schema-rejected (the audited
  `--allow-glob '**'` workaround is retired). Default fixes in both modes: `.parallax/**` is
  shared contract surface; `bin` is out of the compiled-dir defaults (`--compiled-glob 'bin/**'`
  restores it). Harness: `tests/t_blindfold_monorepo.sh` + `[blindfold_monorepo]`.
- **Pre-freeze closure (mechanical).** `pre-freeze-state.json` requires a `closure` object
  (`{open, independent-pass}` — no self-attested status is representable); only
  `pre-freeze-budget.py record` writes it, only on that round's schema-valid verifier `pass`;
  semantic validation re-derives it from the round inventory in both directions on every read.
  A human `grant-one` buys one round, never a certification. *(directive)* `spec.md` gates every
  no-human-OK path on `--autonomous --from-doc` together — plain `--from-doc` keeps the human OK.
  Harness: `tests/t_pre_freeze_closure.sh` + `[pre_freeze_closure]`.
- **Review-ledger path identity (mechanical).** `merge-ledger.py --repo-root` canonicalizes the
  fingerprint's file component against tracked files (exact → unique suffix → unique basename);
  ambiguous basenames stay distinct with loud `path_warnings` — never a silent merge. Harness:
  `tests/t_merge_ledger_path_drift.sh` + `[merge_ledger_path_drift]`.
- **Run-phase evidence (mechanical helper + directive wiring).** `scripts/evidence-event.py`
  appends schema-validated events (nine new build-phase types) and moves `run-evidence.json`
  status under full-document validation; `run.md` wires it at every Phase 2-5 transition, so the
  v0.36 auditability contract holds past `spec_frozen`. Harness:
  `tests/t_evidence_events_run_phase.sh` + `[run_phase_evidence_events]`.
- **UI user-reachability (directive — explicitly NOT mechanical).** A `user-reachable` frontend
  seam requires interaction proof (drive the entry affordance, assert destination content),
  never router membership alone; with no render harness, the limitation is recorded and the
  cross-model verifier inspects reachability. The harness locks only presence
  (`[ui_reachability]` + `tests/frontend-reachability-eval-cases.md` for LLM-judged evals).
- **Provider transport (mechanical helper + directive).** Canonical `codex exec … < /dev/null`;
  `scripts/strip-openai-schema.py` for top-level-`allOf` schemas (full schema stays the
  acceptance bar); a silent timeout is a hang, never a rate limit. Harness: `[provider_transport]`.

## v0.37.5 — governance self-attestation hardening (the F3-family's second halves)
Two real v0.37.4 production runs (`ANALYSIS_v0.37.4_live_production_runs.md`, `TRIAGE_v0.37.4_live_runs_to_v0.37.5.md`
— findings, never a benchmark) proved the v0.37.3 P0s held, and surfaced the same self-attestation
threat model at three boundaries the mechanics did not yet cover. v0.37.5 mechanizes each, fail-closed:

- **Freeze-gate mode binding (mechanical; gates A1+A2).** `pre-freeze-state.json` pins a required
  `mode.autonomous` at init; every `pre-freeze-budget.py` call must match it (a console relabel is a
  GateError); the new `freeze-check` subcommand is the freeze gate both modes must pass — autonomous
  allows ONLY `closure.status=independent-pass` (a human at the console, a missing state, or
  `on_missing=warn` changes nothing; park/escalate instead), `grant-one` refuses under autonomous, and
  a hand-edited grant invalidates the state on the next read. Harness: `tests/t_freeze_mode_binding.sh`.
- **Immutable round budget (mechanical; gates A3+A5).** `pin-policy` freezes the `[review]` policy +
  its triage-canonical hash into `.parallax/<slug>/review-policy.frozen.json` at spec-freeze,
  committed with the contract and immutable. `merge-ledger.py --pinned-policy` refuses a round beyond
  the effective budget at ingestion; `triage.py --pinned-policy` disposes under the pin; `epic-gate.py`
  derives the authority from the COMMITTED pin + recorded `BA-*` review-budget amendments
  (`contract-amend.py record-budget`, human-repeated machine-minted token, hash-chained via
  `scripts/budget_chain.py`), requires the committed codex.toml to hash-match it, and accepts ledger
  hashes only ON that chain. The audited live bypass — sed `max_rounds 2→3` + re-stamp all ledgers +
  commit — is a harness case and still HOLDs. The v0.37 P0.4 contract chain remains
  mechanical-tightening-only. Harness: `tests/t_pinned_budget.sh`.
- **Post-green receipt integrity (mechanical; gate A4).** Every verifier round persists the verbatim
  provider verdict as `reviews/<slice>.round<r>.raw.json` (symmetric with pre-freeze); `merge-ledger.py`
  ingests only a schema-valid round whose `--raw-response` equals it, and records
  `{round, raw_artifact, raw_sha256}` receipts the ledger schema now requires; `triage.py` escalates on
  uncovered rounds; `epic-gate.py` re-reads every committed raw (sha256 + round-schema). A malformed
  envelope is a provider error — retry/fallback — never material for an orchestrator-authored pass.
  Harness: `tests/t_postgreen_receipts.sh`.
- **Resume integrity (mechanical; gate B1).** `scripts/resume-reconcile.py`: run-state is a checkpoint,
  git is the truth — drift refuses (exit 2) or writes back the real tips with a mandatory
  `session_handoff` seam; run.md re-persists tips after every arbiter round. Harness:
  `tests/t_resume_reconcile.sh`.
- **Production-path seam proof (mechanical + directive; gate C1).** `feature-sweep.py` rejects a
  `required_consumers` match found only in test files (a test-authored duplicate is not a consumer;
  `production_only:false` is a recorded opt-out); `role-arbiter` verifies the cited test drives the
  real production symbol. Harness: `tests/t_production_seam.sh`.
- **Receipted sweep + honest telemetry (D1–D3).** `feature-sweep.py --receipt` writes
  `sweep-receipt.json` (manifest-sha-bound) and `finalize-gate.py` refuses prose-only "clean";
  finalize self-audits iteration undercount (non-blocking warning); the lease is real-or-dropped;
  `--transcript-path` must name the session `.jsonl` itself.
- **OpenAI-strict shim (E1).** `strip-openai-schema.py` emits a fully strict call copy in one pass and
  `normalize` re-validates responses against the FULL schema — zero hand-tuned retries, acceptance bar
  unweakened.

**Still owed (measurement, not code — gate F1g):** the true cross-package monorepo blindfold case and a
real autonomous freeze-gate exercise belong to the v0.37.5 production soak (≥1 multi-package run, ≥1
autonomous `--from-doc` run reaching the freeze gate).

## v0.38 — adopt & multi-session continuity (resume vs adopt)
v0.38 is a **capability** minor, not another hardening pass: it closes the operational gap the
v0.37.4 soak exposed (RUN2 `linkedin-selfservice-bot` hit context exhaustion mid-build; its
background tracks' completion notifications did not cross the session boundary, so the operator
hand-wrote `RUN-HANDOFF.md` and did manual git archaeology). Public claims stay design-intent until
a production soak exercises adopt.

**Resume vs adopt — two distinct recovery paths (do not conflate).**
- **`--resume`** keys on a **clean** `status=paused-on-limit`: an eager checkpoint, an exact
  per-slice tip resume, the cloud-atomic lock lease. Unchanged in v0.38.
- **`--adopt`** (new) keys on an **unclean** `status=running` interruption: the session died, and one
  or more blind tracks are in-flight **background** branches the checkpoint doesn't fully reflect. It
  reconstructs ground truth **git-first** and continues, failing closed on anything it cannot resolve.
  It **consumes** the v0.37.5 F7 reconciliation (`resume-reconcile.py`) for tips — it does not
  re-implement it.

- **Dispatched-subagent manifest (F8; mechanical; gate M1).** `.parallax/<slug>/subagents.json`
  (schema `assets/subagents.schema.json`) records every dispatched track — `{slice, role, branch,
  wave_base, dispatched_at, session_id, mode, status, reported_commit?}` — written at dispatch by
  `scripts/subagent-manifest.py record` and committed to `feature/<slug>`. `reconcile` resolves each
  entry against live git: a vanished branch ⇒ `stale` (never trusted), a background branch ahead of
  `wave_base` ⇒ reaped with its git tip as `reported_commit`, a recorded commit conflicting with the
  live tip ⇒ surfaced. Harness: `tests/t_subagent_manifest.sh`.
- **Adopt reconstructor (mechanical; gates A1–A5).** `scripts/adopt-reconcile.py` takes the lease
  safely (a **live** lease held by another session ⇒ refuse; an **expired** one is stealable),
  reconciles tips via F7 (git wins), reaps in-flight background tracks via F8, then classifies each
  slice: `integrated` → skip (A2); both tracks ahead → reap + assemble (A3); one track missing →
  re-dispatch only that track blind, keep the present one (A4); neither track carries work, or a
  tip-conflict ⇒ **escalate + stop** (A5). It stamps run-state `adopted_from` (+ a `subagents` path);
  `run.md` gains an *Adopt* subsection parallel to *Resume*, `auto.md` a headless `--adopt`. Harness:
  `tests/t_adopt.sh` (incl. interruption scenarios A-P1/A-P3).
- **Machine handoff (mechanical; gate H1).** `scripts/render-handoff.py` deterministically renders
  `.parallax/<slug>/handoff.md` — integrated slices, in-flight tracks with branch/commit/status, owed
  verifications, escalations, the exact `--adopt` command — with no operator free-text field. It is the
  durable replacement for the hand-written `RUN-HANDOFF.md`. Harness: `tests/t_render_handoff.sh`.
- **Adopt-critical evidence mandatory (mechanical + directive; gate E1-adopt).** `evidence-event.py
  audit-slice` flags a slice integrated with no `slice_dispatched`/receipt evidence even on a
  hand-driven/degraded path, instead of accepting it silently. Harness: `tests/t_evidence_required.sh`.

Adopt **never** fabricates a missing track (re-dispatching it blind is not fabrication — guessing its
artifact would be) and **never** marks a slice done without its arbiter/verifier receipts. That is the
exact failure this release prevents; the stop conditions are a hard part of the contract.

## v0.39 — gate reachability in the real environment (hand-driven & monorepo)
The v0.31→v0.38 arc made the gates **mechanical**; the first true multi-package monorepo soak
(`ANALYSIS_v0.38.1_live_production_runs.md`, `TRIAGE_v0.38.1_live_runs_to_v0.39.md` — findings, not a
benchmark) showed they are **un-exercised in production**: every run was HAND-DRIVEN, so the gates
never fired on the box, and the detached-HEAD hazard B1 mechanizes was caught by a human. v0.39 makes
them reachable on the hand/monorepo path and removes the friction that causes the hand-driving. A
clean skill-flow run is behaviorally identical to v0.38.1; this only *adds* fail-closed coverage.

- **Hand-driven / degraded finalize (mechanical; gates HG1–HG3).** A **flag on `/parallax:run`'s
  done-gate** (`--finalize <slug>`, or auto-detected on a hand-integrated slice) — NOT a new command —
  routes the hand path through `scripts/finalize-handdriven.py`, which REUSES the existing gates:
  **HG3** refuses a stale tip (`recorded_tip != git rev-parse <branch>`, the B1 invariant on the hand
  path); **HG2** routes the hand-committed post-green raw verdict through `merge-ledger.py` (schema-gate:
  a malformed/hand-authored verdict is a provider error) then `triage.py` (must dispose GREEN) before
  it can unblock a merge; **HG1** emits the adopt-critical receipts and runs `evidence-event.py
  audit-slice`, failing closed (E1) if an integrated slice lacks them. Harness:
  `tests/t_finalize_handdriven.sh`.
- **Monorepo silent-failure guards (mechanical; gates D1/D2).** **D1** — `blindfold-guard.py
  --assert-pathspec-match` fails closed when the blindfold `git rm` pathspec matches ZERO files (the
  canonical `**/*.test.ts` silently no-ops on a `src/`-prefixed pnpm workspace, leaving the tree
  un-blindfolded); a test-less slice records `--allow-no-tests`. **D2** — `scripts/push-guard.sh`: a
  pre-push `git fetch` + `merge-base --is-ancestor` ancestry check and a `branch-ref == HEAD` assertion
  after every commit, mechanizing the moving-`main` / detached-HEAD checks the owner did by hand; wired
  into the Step-4 feature + epic pushes. Harness: `tests/t_monorepo_guards.sh`.
- **CI/lint parity (mechanical; §5.3).** The validation contract may declare a per-check
  `ci_equivalent` (whole-tree) command; the arbiter runs the local AND CI-equivalent forms through
  `scripts/ci-parity.py`, so a slice green locally but red under the whole-tree CI form is NOT green.
- **F1 guard:196 hardening (mechanical; §5.4).** `blindfold-guard.py --base-ref` — in scope mode a
  NEW-since-base impl file absent from `protected_impl_paths` fails closed on the test side even under a
  broad `dependency_allow_globs` root.
- **Done-gate telemetry regeneration (mechanical; §5.5).** `evidence-event.py update-run
  --restamp-version` re-stamps `run-evidence.json` to the live plugin version at the done-gate
  (RUN-A still read a spec-phase-frozen `0.36.1`) and moves `status` off `frozen-spec`.
- **CLI foot-guns (mechanical; §5.6).** `triage.py --schema` resolves against `__file__` (worktree-safe);
  `pre-freeze-budget.py record` accepts a JSON string OR a path; a post-dispatch `push-guard.sh
  committed` assertion confirms each track committed to the RIGHT branch.

**Carried (validation, not code):** the Cluster B adopt soak and the F1g monorepo skill-flow soak are
scheduled, not discharged — the "gates protect production" claim stays out until one runs.

## What v0.37 is not
Not a benchmark or quality claim, not a new product surface, and not a weakening of the Codex
cross-model verifier (the live runs showed it catches real defects; the fix is controlled
verifier-limited continuation, never removing the gate). Dismissed gaps `G18` (owner-scoped
build-ahead-of-data) and `G23` (weak harness/environment evidence) were **not** treated as release
drivers. The same holds for v0.37.3: a remediation of confirmed live-run defects, not a claim
that the plugin is production-ready — the three runs remain design input, not benchmark evidence.
