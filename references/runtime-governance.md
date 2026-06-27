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

## What v0.37 is not
Not a benchmark or quality claim, not a new product surface, and not a weakening of the Codex
cross-model verifier (the live runs showed it catches real defects; the fix is controlled
verifier-limited continuation, never removing the gate). Dismissed gaps `G18` (owner-scoped
build-ahead-of-data) and `G23` (weak harness/environment evidence) were **not** treated as release
drivers.
