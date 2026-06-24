# Existing Affordance Review — prompt-level regression cases

These exercise the v0.31 **Existing Affordance Review** patch to `/parallax:spec`
(DESIGN_v0.31_existing_affordance_patch.md §9). The patch is a **prompt/contract**
change — there is no new command, script, schema, or state — so its behaviour is
**LLM-judged**, not unit-testable by `tests/run.sh`. `run.sh` only locks the wiring
(the `[affordance_review]` checks: the Step 3.5 review, the spec-format section, the
always-applies self-review pass, the pre-freeze overbuild scope, and that no new
command/script/schema was added). These cases are the behavioural eval set a human
(or a judging model) runs against a real `/parallax:spec` session.

## How to run a case
1. In a scratch repo, lay out the **repo fixture** (the seam the case hinges on).
2. Run `/parallax:spec "<brief>"` (interactive, or `--from-doc` with the brief).
3. Read the frozen `.parallax/<slug>/spec.md` and the proposed approaches.
4. Score against **Pass criteria**. A case **fails** if the spec freezes a new
   subsystem while a plausible existing affordance was never recorded as checked or
   rejected, or if the short path was chosen in a way that relaxes a safety /
   ambiguity / validation gate.

A case is a *behavioural* check; treat a green `tests/run.sh` as necessary but not
sufficient. Record real runs (date, model, outcome) below each case as evidence.

---

### E1 — Existing registry wins (thin overlay)
**Brief:** "We need a global registry so scripts can expose globals."
**Repo fixture:** the engine already exposes `registerGlobalObject(name, value)` (or
an equivalent registration API) in an obvious, readable place.
**Expected spec:**
- the leading approach uses the existing registration API;
- no new registry / lifecycle / API is introduced;
- the `Existing affordance review` section **cites the registry file** as evidence;
- chosen implementation shape = **thin overlay**.
**Pass criteria:** new registry *not* proposed as the leading approach; the registry
candidate appears in the review table with a concrete evidence path and `viable: yes`.

### E2 — Hook/command table wins (entry, not dispatcher)
**Brief:** "Add a handler for a new command/action."
**Repo fixture:** an existing command table / router map / dispatch table.
**Expected spec:**
- the change is an **entry in the existing table**, not a new dispatcher;
- no new routing subsystem;
- acceptance criteria cover the **observable command behavior** (not the wiring).
**Pass criteria:** the review table names the command/router map; the chosen shape is
a thin overlay/local change; no new dispatcher subsystem is frozen.

### E3 — New module is justified (and recorded as such)
**Brief:** "Add a retry policy with persisted backoff state across restarts."
**Repo fixture:** no existing scheduler / retry-persistence; existing hooks are
**stateless**.
**Expected spec:**
- a thin hook-only approach is presented and **`rejected`**, with the concrete reason
  (a stateless hook cannot persist backoff across restarts);
- a **new module is allowed**, with its new responsibility (durable backoff state)
  stated explicitly;
- validation covers the **persistence** behavior.
**Pass criteria:** the new module is *not* flagged as overbuild, because the review
records *why each plausible affordance is insufficient*. (This is the control case:
the patch must not punish a genuinely-needed subsystem.)

### E4 — Thin overlay rejected for safety (don't take the shortest path blindly)
**Brief:** "Expose an admin-only operation through the existing public route."
**Repo fixture:** the existing public route table can *technically* add the entry, but
the **auth boundary differs** (the route is unauthenticated/public).
**Expected spec:**
- the review **cites the existing route table** as a candidate;
- it **rejects it as insufficient/unsafe** unless the auth semantics are extended
  explicitly — the short path is not chosen merely because it is short;
- the safety boundary is part of the acceptance criteria.
**Pass criteria:** the affordance is recorded but `viable: no` with a safety reason;
the spec does not quietly widen a public route into an admin path.

### E5 — Resolve regeneration (fresh review for the new generation)
**Starting point:** generation 1 parked on a spec-gap (per v0.31 safe-completion).
**Human decision:** choose a behavior that can now be implemented through an existing
config map.
**Expected generation-2 spec:**
- has a **fresh** `Existing affordance review` derived from the current code;
- does **not** reuse the generation-1 review as evidence (the old one lives only in
  `history/generation-1`);
- still mints a new `run_id` and performs full invalidation per v0.31 (the affordance
  pass is never a basis for partial invalidation or a "ship anyway").
**Pass criteria:** gen-2 `spec.md` carries its own review section; the gen-1 review is
absent from the active path and present only under `history/generation-1`.

### E6 — Reviewer catches a formal/empty section
**Candidate spec:** has an `Existing affordance review` that says "checked repo, none
found", **but** the changed files obviously include `plugins.register(...)` or
`routes = {}` (an existing seam in plain sight).
**Expected pre-freeze review:**
- returns at least a **`medium`** (the review section is formal/empty against the
  evidence in the contract);
- returns a **`high`** if a new subsystem is proposed despite the obvious existing
  affordance.
**Pass criteria:** the pre-freeze `codex-judge` finding is `medium`/`high` with a
repo-evidence `where`/`claim`; it is **not** a style nit about helper naming.

---

## Non-negotiable failure conditions (DESIGN §11 — any one fails the patch)
- a new command/module/state machine was introduced for affordance review;
- "8 lines" became a hard LOC rule;
- ambiguity/safety/validation was skipped because an existing seam exists;
- the resolver was allowed to avoid a new generation / full invalidation;
- a rejected affordance was recorded with **no evidence path**;
- the pre-freeze reviewer blocked on a style preference instead of repo evidence.

## Verification note
`claude plugin validate parallax_push` is part of the release gate
(DESIGN §10.5). If the `claude` CLI is unavailable in the run environment, record
that as a **verification gap**, not as a pass.
