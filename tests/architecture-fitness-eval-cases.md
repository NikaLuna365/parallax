# Architecture Fitness — prompt-level regression cases

These exercise the v0.32 **Architecture Fitness** check in `/parallax:spec`
(TZ_v0.32_architecture_fitness.md §P5 / §9). Like the v0.31 affordance review, this
is a **prompt/contract** change — no new command, script, schema, or finding kind —
so its behaviour is **LLM-judged**, not unit-testable by `tests/run.sh`. `run.sh`
only locks the wiring (`[architecture_fitness]`: the Step 4.5 check, the spec-format
section, the always-applies self-review pass, the codex-judge calibration, the role
seam instructions, and that no `/parallax:architecture` command or scout/fanout was
added). These cases are the behavioural eval set a human (or a judging model) runs.

## What v0.32 must prove (and what it must not)
It must catch the **obvious** AI maintainability failures (A1–A6) that downstream TDD
would honestly green; it must **not** become an architecture consultant, block on
style/folder/naming, or demand a deep module for every small feature. So the set
deliberately includes **non-blockers** (F7, F8) and the v0.31 carry-over (F9).

## How to run a case
1. In a scratch repo, lay out the **repo fixture** (the seam/contract the case hinges on).
2. Run `/parallax:spec "<brief>"`; read the frozen `.parallax/<slug>/spec.md`
   **Architecture fitness** section + proposed approaches.
3. Score against **Pass criteria**. A case **fails** if a real A1–A6 blocker is frozen
   without resolution, or if a style-only/imperfect-but-fine shape is blocked.

A green `tests/run.sh` is necessary but not sufficient; record real runs below each case.

---

### F1 — Shallow wrapper rejected (A2)
**Brief:** "Add a `UserService` that wraps the existing `userRepo` calls."
**Repo fixture:** `userRepo` already exposes the needed methods; the proposed service only forwards them.
**Expected:** the Architecture fitness **Module depth** flags a shallow wrapper that hides nothing; the spec drops the pass-through layer (callers use `userRepo` directly) or states the real complexity the service hides.
**Pass criteria:** a no-op forwarding layer is **not** frozen as build-ready.

### F2 — Wrong private-helper test seam rejected (A1/A5)
**Brief:** "Add discount calculation; test it."
**Repo fixture:** discount is reachable through a public `priceQuote()` boundary, but the draft tests target an internal `_applyDiscount` helper.
**Expected:** **Public seam** / **Regression seam** flag testing a private helper when the public seam reproduces the behaviour; the spec names `priceQuote()` as the regression seam.
**Pass criteria:** the frozen regression seam is the public boundary, not a private helper; blind-coder is not asked to export the helper just for tests.

### F3 — Duplicated business rule rejected (A3)
**Brief:** "Apply a 15% fee in checkout and in the invoice PDF."
**Repo fixture:** no shared fee module; the draft inlines `0.15` in both call sites.
**Expected:** **Locality** flags duplicated business logic; the spec puts the rule in one source of truth both callers use.
**Pass criteria:** the fee rule has a single declared home; the spec does not freeze the literal in two places.

### F4 — Speculative single adapter/port rejected (A4)
**Brief:** "Add a `PaymentProvider` port so we can swap providers later."
**Repo fixture:** exactly one provider exists now; no second implementation is in scope.
**Expected:** **Variation** flags a speculative adapter/port with no current variation; the spec implements directly until a real second provider exists.
**Pass criteria:** a one-implementation abstraction "for the future" is **not** frozen.

### F5 — External dependency adapter ALLOWED (control — not every adapter is bad)
**Brief:** "Integrate the Stripe SDK behind our own interface."
**Repo fixture:** a real external dependency (Stripe) with a genuine boundary to isolate.
**Expected:** the adapter is **justified** — **Adapter/port justification** records the current variation (an external dependency we must isolate/mock); Architecture fitness passes.
**Pass criteria:** a genuinely-justified adapter is **not** flagged as overbuild (the gate must not punish a real seam).

### F6 — Local ADR conflict blocked (A6)
**Brief:** "Add a direct DB query in the controller for speed."
**Repo fixture:** `docs/adr/0007-no-db-in-controllers.md` (or `AGENTS.md`) forbids DB access in controllers.
**Expected:** **Local architecture contract** flags the silent violation; the spec respects the ADR (goes through the repository layer) or records an explicit, decided conflict — never silently breaks it.
**Pass criteria:** the ADR is cited and honoured (or the conflict is an explicit recorded decision), not ignored.

### F7 — Style-only suggestion does NOT block (false-positive guard)
**Brief:** "Add an `isEligible(user)` predicate."
**Repo fixture:** a perfectly fine local shape; the only quibble is a reviewer preferring the name `checkEligibility` or a different folder.
**Expected:** naming/folder/style preference is `low` and **does not block**; the spec freezes.
**Pass criteria:** a style-only finding **cannot** stop the freeze. (This is the explicit false-positive case the TZ requires.)

### F8 — Small imperfect local shape passes
**Brief:** "Add a one-off CSV export helper for the admin page."
**Repo fixture:** a small, local feature with no real seam pressure; a slightly imperfect but reasonable local function.
**Expected:** Architecture fitness is short but non-empty; no deep module is demanded; the spec freezes.
**Pass criteria:** the gate does **not** force a new abstraction onto a small feature (no "every feature needs a deep module").

### F9 — Existing registry / thin overlay still covered by v0.31 (carry-over)
**Brief:** "We need a global registry so scripts can expose globals."
**Repo fixture:** the engine already exposes `registerGlobalObject(name, value)`.
**Expected:** the v0.31 **Existing affordance review** still leads to a thin overlay on the existing registry; Architecture fitness agrees (the public seam is the registry) and adds no conflicting demand.
**Pass criteria:** v0.31 affordance behaviour is unchanged; Architecture fitness complements it, never contradicts it.

---

## Non-negotiables (TZ §3 / §7 — any one fails the patch)
- a new `/parallax:architecture` command, sub-agent/scout fanout, or repo-wide audit was introduced;
- a new schema/kind was added when the existing kinds (`spec-gap`/`code-fault`/`test-fault`/`low`) sufficed;
- epic/main gates, blind-TDD, no-peeking, contract hash, verifier, or stale-generation checks were weakened;
- a style/folder/naming preference became a blocker;
- a `/parallax:resolve` new generation reused an old generation's Architecture Fitness notes as certification.

## Verification note
`claude plugin validate parallax_v032_work` is part of the gate. If the `claude` CLI
is unavailable, record that as a **verification gap**, not a pass.
