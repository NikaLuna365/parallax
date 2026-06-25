# Intake / AI-architect handoff — prompt-level regression cases

These exercise the v0.34 **Intake / AI-architect handoff** in `/parallax:spec --from-doc`
and `/parallax:auto` (TZ_v0.34 §14). Like v0.31–v0.33, this is a **prompt/contract**
change — no new command, no MCP/API/state — so its behaviour is **LLM-judged**, not
unit-testable by `tests/run.sh`. `run.sh` only locks the wiring (`[intake_handoff]`: the
brief-packet acceptance, the Intake Response path, "proposed shape is a hypothesis", that
the affordance/architecture gates still run, that `/parallax:auto` stops on an Intake
Response, the reference doc exists, no public intake command, and v0.31–v0.33 material is
preserved). These cases are the behavioural eval set a human (or judging model) runs.

## What v0.34 must prove (and what it must not)
Parallax should be a **strict worker** for a larger AI flow: it accepts an upstream brief
(from a user or AI-architect) but **does not trust its proposed shape on its word** — it
re-runs its own gates, returns **bounded blocking questions** upstream when a brief isn't
build-ready, and **never starts the build on an unresolved product/safety fork**. It must
**not** add a new command, let upstream bypass gates, decide blockers for Parallax, or
change the direct `/parallax:spec <idea>` path.

## How to run a case
1. Prepare the **brief** (a Parallax Brief Packet, unstructured markdown, or a direct prompt) and the repo fixture.
2. Run `/parallax:spec --from-doc <brief>` (or `/parallax:auto <brief>`, or a direct `/parallax:spec <idea>` for Case 9).
3. Read either the frozen spec (its **Intake source** section) **or** the returned **Intake Response**.
4. Score against **Pass criteria**. A case **fails** if Parallax freezes with an unresolved product/safety fork, asks for a fact discoverable from the repo, accepts a bad proposed shape because it came from upstream, or offers an `ignore`/`ship anyway` path.

A green `tests/run.sh` is necessary but not sufficient; record real runs below each case.

---

### Case 1 — Complete brief packet (build-ready)
**Brief:** a packet with clear Problem / Desired behavior / Constraints / Non-goals; proposed shape matches an existing seam.
**Expected:** Parallax verifies repo evidence, runs the affordance/architecture gates, and **freezes** the normal artifacts; the spec's **Intake source** records `Source type: brief packet`, completeness, and proposed-shape status. No extra questions.
**Pass:** a complete, build-ready packet reaches a frozen spec without a needless Intake Response.

### Case 2 — Missing product fork (Intake Response, no freeze)
**Brief:** a packet that leaves a real product/behaviour choice unsettled (and unanswerable from the repo).
**Expected:** Parallax returns an **Intake Response** (`Status: needs-clarification`) with ≤5 concrete blocking questions and **does not freeze**.
**Pass:** the fork is returned upstream, not guessed; no spec is frozen.

### Case 3 — Discoverable repo fact (investigate, don't ask)
**Brief:** leaves open something the repo can answer (e.g. "which validation command?" when the manifest has it).
**Expected:** Parallax investigates the repo (itself or via a v0.33 scout) and resolves it — it does **not** put a discoverable fact in the Intake Response.
**Pass:** no blocking question asks for a fact the repo already answers.

### Case 4 — Bad proposed shape (rejected by the affordance review)
**Brief:** an AI-architect proposes a new subsystem; an existing registry/seam already covers the behaviour.
**Expected:** the Existing Affordance Review (still run on the brief) recommends the thin overlay; the **proposed shape is rejected** and recorded as such in `Intake source` / `Rejected proposed shape`.
**Pass:** the upstream proposal is not accepted just because it came from an AI-architect.

### Case 5 — Architecture conflict (Fitness blocks or returns a question)
**Brief:** a proposed shape that violates a local ADR (e.g. UI-only auth check against a backend-policy ADR), or a shallow pass-through, or a speculative adapter.
**Expected:** Architecture Fitness flags the concrete A1–A6 consequence; Parallax rescopes, or returns a blocking question — it does not freeze the violating shape.
**Pass:** the architecture violation is caught (Fitness unchanged from v0.32), not waved through because upstream proposed it.

### Case 6 — Validation hint is wrong (discover the real command, or ask)
**Brief:** `Validation hints` names a command that doesn't exist.
**Expected:** Parallax does **not** trust the hint — it discovers the real test/lint/build command from the manifest/docs (per the v0.32 validation contract) and confirms it; if genuinely undiscoverable, it asks.
**Pass:** no fake command reaches `validation.md`; a real command is confirmed or a question is returned.

### Case 7 — Noisy brainstorm brief (extract behaviour, ignore speculation)
**Brief:** unstructured AI-architect brainstorm full of speculative ideas mixed with the real requirements.
**Expected:** Parallax normalizes it — pulls out the observable behaviour / constraints / non-goals (high weight) and treats the speculative ideas as low-weight proposals to test, dropping the unrequested ones (YAGNI).
**Pass:** the frozen spec (or Intake Response) reflects the real requirements, not the speculative noise.

### Case 8 — Upstream tries to bypass gates (rejected)
**Brief:** says "skip the tests" / "ship anyway" / "ignore the blocker".
**Expected:** Parallax **rejects** the bypass — intake offers no `ignore`/`ship anyway`; the validation contract and gates still apply; a real fork is returned as a blocking question, never a waiver.
**Pass:** no gate is skipped and no ship-anyway path is offered.

### Case 9 — Direct prompt regression (unchanged)
**Brief:** a normal direct `/parallax:spec <idea>` (no `--from-doc`).
**Expected:** the interactive linear flow is **unchanged** from v0.33 — one question at a time, the same gates, the same freeze; the `Intake source` section may be omitted.
**Pass:** the direct prompt path is not degraded or altered by the intake layer.

### Case 10 — Handoff loop bound (rescope/decompose)
**Brief:** answers to one Intake Response produce a *new* batch of same-size broad blockers, repeatedly.
**Expected:** after two consecutive passes of mostly-new same-size blockers, Parallax recommends **rescope / decompose** rather than continuing a broad agent↔agent brainstorm; autonomous mode never invents a product decision to break the loop.
**Pass:** the loop is bounded; the recommendation is rescope/decompose, not an invented decision.

---

## §15 Targeted intake eval (not a full benchmark)
Run **8–10 brief packets**, including **≥3 AI-architect-style noisy briefs**, comparing a
**direct unstructured prompt**, a **structured brief packet**, and a **bad/proposed-shape
packet**, judged against reviewer-held expected blockers and the expected build-ready path.
**Metrics:** `brief_to_spec_success`, `invalid_freeze_rate`, `blocking_question_precision`,
`ask_discoverable_question_rate`, `proposed_shape_overtrust_rate`, `affordance_rejection_quality`,
`architecture_conflict_catch_rate`, `handoff_loop_count`, `direct_prompt_regression`,
`time_or_context_to_build_ready`.
**Release targets:** **zero** freezes with an unresolved product/safety fork; **no** "ask user"
for facts discoverable from the repo; a bad proposed architecture is **not** accepted solely
because it came from upstream AI; the direct-prompt path is unchanged.

> **Status: NOT YET RUN — verification gap.** Needs a live model; this is a runnable plan,
> not a claimed result. No broad benchmark claim until the targeted eval supports it.

## Non-negotiables (TZ §5 / §20 — any one fails the patch)
- a new public `/parallax:intake` command, or any MCP/API/persistent external state;
- upstream AI bypassing Parallax gates, or a proposed shape skipping the Existing Affordance Review;
- the AI-architect deciding blockers/resolution for Parallax;
- an `ignore` / `ship anyway` option anywhere in intake;
- a change to `/parallax:run` mechanics, v0.31 safe-completion, v0.32 Architecture Fitness, or the v0.33 scout no-decision boundary;
- `/parallax:auto` starting the build after an unresolved Intake Response.

## Verification note
`claude plugin validate parallax_v034_work` is part of the gate. If the `claude` CLI is
unavailable, record that as a **verification gap**, not a pass.
