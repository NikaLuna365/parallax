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

## What v0.37 is not
Not a benchmark or quality claim, not a new product surface, and not a weakening of the Codex
cross-model verifier (the live runs showed it catches real defects; the fix is controlled
verifier-limited continuation, never removing the gate). Dismissed gaps `G18` (owner-scoped
build-ahead-of-data) and `G23` (weak harness/environment evidence) were **not** treated as release
drivers. The same holds for v0.37.3: a remediation of confirmed live-run defects, not a claim
that the plugin is production-ready — the three runs remain design input, not benchmark evidence.
