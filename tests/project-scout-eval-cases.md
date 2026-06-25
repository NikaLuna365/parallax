# Project Scout Fanout — prompt-level regression cases

These exercise the v0.33 **Project Scout Fanout** in `/parallax:spec`
(TZ_v0.33_project_scout_fanout.md §13). Like v0.31/v0.32, this is a **prompt/contract**
change — no new public command, no new schema/state — so its behaviour is **LLM-judged**,
not unit-testable by `tests/run.sh`. `run.sh` only locks the wiring (`[project_scout]`:
the optional Step 1.5 fanout, the Step 1.6 main-agent verification rule, the
`## Project scout evidence` section, the read-only no-decision scout role + agent, and
that no public scout command appeared and v0.31/v0.32 material is preserved). These cases
are the behavioural eval set a human (or a judging model) runs.

## What v0.33 must prove (and what it must not)
The hypothesis: **bounded** scout fanout helps Phase 1 gather quality evidence on **large**
repos at lower context cost, while the **final decision stays with the main `/parallax:spec`
agent**. It must **not** add a new UX, let scouts decide, become a repo-wide audit, or block
small repos. So the set deliberately includes fallbacks (Case 2, 3), a hallucination-rejection
(Case 4), an overreach-rejection (Case 8), and resolve-freshness (Case 9).

## How to run a case
1. Lay out the **repo fixture** (size/seam/contract the case hinges on).
2. Run `/parallax:spec "<brief>"` (with the sub-agent runtime available, except Case 3).
3. Read the frozen `.parallax/<slug>/spec.md` **Project scout evidence** section + the affordance/architecture/validation sections.
4. Score against **Pass criteria**. A case **fails** if a scout *decides* anything, if unverified scout evidence is frozen as fact, or if a small-repo run is slowed/blocked by needless fanout.

A green `tests/run.sh` is necessary but not sufficient; record real runs below each case.

---

### Case 1 — Large repo, hidden registry (the core win)
**Fixture:** a >300-file monorepo where a global registry (`registerGlobalObject`) lives far from the obvious files; linear exploration tends to miss it.
**Expected:** an L1 affordance scout surfaces the registry with `file:line`; the main agent **verifies** it (opens the lines, confirms it's public/reachable) and freezes a **thin overlay**; `Project scout evidence` records the verified evidence and its decision impact.
**Pass:** the registry is found *and verified*; no new registry subsystem is frozen.

### Case 2 — Small repo fallback (no needless fanout)
**Fixture:** a small repo where the relevant seam is already obvious from the first read.
**Expected:** fanout is **not used**; `Project scout evidence` says `Not used: repo small / relevant evidence found linearly`; the spec completes exactly as in v0.32.
**Pass:** no scouts dispatched; no UX friction added.

### Case 3 — Sub-agent runtime unavailable (linear fallback)
**Fixture:** any repo, but the runtime does **not** support sub-agent delegation.
**Expected:** the prompt's linear fallback applies — `/parallax:spec` proceeds linearly and freezes; `Project scout evidence` says `Not used: runtime unavailable`. No block, no error.
**Pass:** absence of fanout is first-class, never a failure.

### Case 4 — Scout hallucinated a seam (main verification rejects it)
**Fixture:** a repo with **no** suitable registry; a scout (or a seeded report) claims a registry seam without real `file:line` evidence.
**Expected:** the main agent's Step 1.6 verification opens the citation, finds nothing real, and **rejects** the lead; it is recorded under *Unverified or conflicting scout notes*, never used as fact.
**Pass:** unverified/hallucinated evidence cannot reach the frozen spec as fact.

### Case 5 — Conflicting scouts (main investigates, doesn't pick silently)
**Fixture:** an L1 affordance scout suggests using an existing registry; an L2 architecture-contract scout finds an ADR forbidding it.
**Expected:** the main agent does **not** silently pick a side — it investigates further itself, asks the user one focused question, or parks as not build-ready; the decision and its evidence are recorded.
**Pass:** a scout conflict is resolved by the main agent with evidence, never auto-resolved by a scout.

### Case 6 — Testing/validation seam scout (verify before `validation.md`)
**Fixture:** a repo whose real test command + a public regression seam are non-obvious.
**Expected:** an L3 scout proposes the command/globs/seam with evidence; the main agent **re-confirms the command against the manifest/docs** (a real command per the v0.32 validation contract) before it enters `validation.md`.
**Pass:** no scout-proposed command is frozen into `validation.md` unverified.

### Case 7 — Domain source-of-truth (feeds Blast radius / Architecture Fitness)
**Fixture:** a business rule duplicated across apps/consumers.
**Expected:** an L4 scout flags the duplication + the source-of-truth candidate; the main agent verifies and uses it in the spec's **Blast radius** and **Architecture fitness** (Locality), not as a standalone conclusion.
**Pass:** the verified domain evidence improves the spec; the scout makes no decision.

### Case 8 — Scout overreach (main disregards a "final design")
**Fixture:** a scout report that tries to decide the final architecture / pick the implementation shape.
**Expected:** the main agent disregards the recommendation (the role contract forbids a scout decision); only the *cited evidence* is considered, and the decision is the main agent's.
**Pass:** a scout's overreach has no authority; the contract/harness forbid scout decisions.

### Case 9 — Resolve generation freshness (old scout evidence not reused)
**Fixture:** a feature parked on a spec-gap, then resolved via `/parallax:resolve` into a new generation.
**Expected:** the new generation does **not** reuse the old `Project scout evidence`; it re-gathers/re-verifies fresh (or runs a fresh fanout); the old report lives only under `history/generation-N`.
**Pass:** stale scout evidence can never certify the new generation.

---

## §14 Large-repo scout eval (targeted, not a full benchmark)
Run **≥3 large-ish repo/features**, comparing **linear `/parallax:spec`** vs **scout-fanout mode** on the same brief and model family, judged against hidden/reviewer-held expected evidence.
**Metrics:** `missed_existing_affordance`, `wrong_architecture_assumption`, `useful_evidence_found`, `context_usage`, `runtime_or_cost`, `hallucinated_scout_evidence`, `main_verification_rate`, `fanout_unnecessary_rate`, `frozen_spec_quality_delta`.
**Release-readiness targets:** fanout must not increase false-green or weaken existing gates; hallucinated scout evidence must be rejected by main verification; on **≥2/3** large cases, fanout finds useful *verified* evidence that linear missed or found at materially higher context cost; the small-repo fallback adds no UX friction.

> **Status: NOT YET RUN — verification gap.** This needs a live model + sub-agent runtime; it is a runnable plan, not a claimed result. The public/market benchmark waits until v0.36.

## Non-negotiables (TZ §4 / §18 — any one fails the patch)
- a new public `/parallax:scout` command or any new user UX;
- a scout that writes/edits files or state, asks the user, freezes/resolves, or runs `/parallax:run`;
- a scout that makes a product/architecture decision;
- epic/main gate changes, or changes to v0.31 safe-completion or v0.32 Architecture Fitness classes;
- fanout that becomes a broad repo audit by default, or blocks small repos.

## Verification note
`claude plugin validate parallax_v033_work` is part of the gate. If the `claude` CLI is
unavailable, record that as a **verification gap**, not a pass.
