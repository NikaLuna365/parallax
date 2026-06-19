---
name: parallax-core
description: Shared TDD contract for the spec-driven blind-coder pipeline — the read-only spec is the only source of truth; RED→GREEN→verify is split across independent agents; blindness and see-it-fail-first are non-negotiable.
---

# Parallax Core — the shared TDD contract

This is the common floor every pipeline agent stands on (test-writer, blind-coder, arbiter). Your **role** skill says which part of the cycle you own; this skill says what is true for everyone.

## The single source of truth

`spec.md` is the **only** authority on WHAT to build. It is **read-only** — never edit it. It is maximally concrete (intended API signatures, behaviors, edge cases, acceptance criteria) with zero open questions by construction. If something you need is genuinely missing or self-contradictory in the spec, that is a **spec-gap**: do not invent it, surface it (workers report it; the arbiter escalates).

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

If you didn't watch the test fail for the right reason, you don't know it tests the right thing. Violating the letter of this rule is violating its spirit.

## The cycle is SPLIT across independent agents

In an ordinary TDD session one person does red → green → refactor. Here the cycle is **distributed** so the coder is judged against *intent*, not against tests it could game:

- **RED** — owned by the **test-writer**: write the failing test from `spec.md`; watch it fail correctly against a stub.
- **GREEN** — owned by the **blind-coder**: make the spec's behavior real, *without ever seeing the tests*.
- **VERIFY + DIAGNOSE** — owned by the **arbiter**: run the tests; on red, decide *whose* fault it is against the spec, and route the fix.

You own only your part. You never do another role's part "to help."

**Independent verification (optional, cross-model).** Verification may be reinforced by a *different* frontier model — Codex, operated through the `codex-judge` role — reviewing the frozen spec before the blind tracks run (pre-freeze) and the assembled green slice after (post-green). The point is structural independence: the mind that *produced* the work is not the only one that *certifies* it (a model rarely catches its own blind angle). In autonomous mode this cross-model verifier replaces the human OK-gate; a divergence between the Claude arbiter and Codex escalates rather than auto-greening, and the arbiter never overrules a Codex `concerns`. It is opt-in via `.parallax/codex.toml`; absent it, the pipeline runs Claude-only exactly as before.

## The blindness wall (non-negotiable)

The whole design depends on the test track and the code track being **independent**:

- The blind-coder's working tree has `tests/` removed. It writes code from the spec, never from the tests.
- The test-writer's working tree has the coder's `src/` removed. It writes tests from the spec, never from the code.
- **Only the arbiter sees both.** Only the arbiter's distilled **natural-language analysis** ever crosses the wall — **never test bodies to the coder, never code to the test-writer.**

Why: when an independent test and an independent implementation disagree, that disagreement is the **primary signal that the spec was ambiguous**. Teaching either side to the other would erase that signal. Protect it.

**Removal is not a sandbox — discipline completes it.** The opposite side is gone from your *working tree*, but it stays reachable through `git` (history, the other track branch, the sibling worktree, reflogs), and workers have Bash. Reaching for it — `git log`/`show`/`cat-file` on the other side, reading the sibling worktree — is **forbidden and counts as gaming the gate**. Removal stops *casual* leakage; this rule stops *deliberate* leakage. Be honest about the guarantee: blindness here is **enforced separation + discipline**, not a hard OS sandbox — it holds because crossing the wall is a gating violation the arbiter treats as a failure, not because it's impossible.

## See it fail first

Never trust a green you didn't earn from a red. A test that passes the first time it runs proves nothing. The test-writer's gate is a test that *executes and fails for the spec'd reason*; the coder's gate is code that *compiles/lints with no stubs left*. The arbiter's job begins only after both gates pass.

## Never game the gate (anti-cheat)

A passing gate must mean the spec's behavior is real — not that someone silenced the check. Across **every** role these are forbidden, and if the arbiter sees them they count as a failure (with an anti-cheat flag), never a green:

- Deleting, skipping, or weakening a test to make the suite pass (`.skip`, `xit`, `@Disabled`, commenting out assertions, loosening an assertion to triviality).
- Updating snapshots/baselines to force green (`--update-snapshots`, `vitest -u`).
- Catching-and-ignoring the very error a test exists to surface.
- Hard-coding an answer that satisfies the spec's *example* while leaving the general behavior unimplemented.
- `git push --force`, `rm -rf`, or any destructive shortcut dressed up as "validation".
- Reaching the hidden side of the blindness wall via `git` (history, the other track branch, a sibling worktree, reflogs) — blindness is enforced by removal **and** discipline; crossing it is gaming, even "just to check".

The only cures for red are: make the spec's behavior real (coder), or make the test encode the spec correctly (test-writer). Never mute the signal.

## Good tests (for those who write or judge them)

- **Minimal** — one behavior per test. An "and" in the name? Split it.
- **Clear** — the name states the behavior.
- **Real** — exercise real code paths. Mocks isolate; they are never the thing under test (asserting on a `*-mock` is a red flag; partial mocks fail silently — mirror the real shape). See `references/obra-test-driven-development/testing-anti-patterns.md`.

## What "done" never means

- Code written before its test exists → delete it; start from the test.
- Tests added afterward "to verify" → not TDD; passing-immediately proves nothing.
- "I manually tested it" → not a substitute for a test that failed first.
