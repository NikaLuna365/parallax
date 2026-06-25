---
name: spec
description: "Phase 1 of the Parallax pipeline. Drive a READ-ONLY interactive brainstorm into ONE maximally-concrete spec with zero open questions, plus a slice manifest and a real validation contract, then freeze them at a gate — a human OK, or in autonomous mode (--from-doc) a machine self-review plus an independent Codex pre-freeze review. Run this before /parallax:run. With --from-doc it accepts a structured Parallax Brief Packet (or unstructured markdown) and, if the brief is not build-ready, returns a bounded Intake Response with blocking questions instead of freezing or building."
argument-hint: "<what you want to build>   |   --autonomous --from-doc <brief-path>"
---

# /parallax:spec — turn an idea into a frozen, build-ready spec

You are running **Phase 1** of the Parallax pipeline for: **$ARGUMENTS**

Your job is to produce, through collaborative dialogue, three frozen artifacts and nothing else:

- `.parallax/<feature-slug>/spec.md` — the single, READ-ONLY source of truth (WHAT to build, not how to test or code it).
- `.parallax/<feature-slug>/slices.md` — the slice manifest (how the work splits, and which agent pair owns each piece).
- `.parallax/<feature-slug>/validation.md` — the validation contract (the project's REAL test/lint/build commands + path globs).

These live under a **per-feature subdirectory** `.parallax/<feature-slug>/`, never the `.parallax/` root. The reason is purely mechanical: two feature branches that both wrote `.parallax/spec.md` would collide add/add on that exact path at merge time, so the second PR in the queue is always red through no fault of its own. Namespacing by slug removes that class of conflict by construction. You derive the slug at the Freeze step.

After this, `/parallax:run` executes the build. You do **not** run it — you stop at the freeze gate.

**Two modes.** *Interactive* (default) is the collaborative dialogue described below. *Autonomous* (`--autonomous --from-doc <brief>`) takes a written brief as the source of truth and runs unattended — the interactive gates are replaced by a machine self-review plus an independent Codex pre-freeze review (see **Autonomous mode** at the end). Use autonomous only when there are **no principled forks left to decide** — an MVP without big decisions, or a spec already brainstormed to where the remaining choices are mechanical.

## Why the bar is "maximally concrete, zero open questions"

This is stricter than ordinary brainstorming, and the reason is structural. In `/parallax:run`, a **blind test-writer** and a **blind coder** work from this spec **independently** — the coder never sees the tests, the test-writer never sees the code. They can only converge if the spec is unambiguous. **Every ambiguity you leave becomes a test↔code divergence later, which the arbiter must escalate as a spec-gap — the most expensive failure mode.** So an ambiguity check here is not a stylistic nicety; it is the core deliverable. If a requirement could be read two ways, pin one — explicitly, with an example.

## Hard rules

- **READ-ONLY on the codebase.** In this phase you may read/explore anything, but you may **not** create or modify any source or test file. The only files you write are the three `.parallax/<feature-slug>/` artifacts. The only git you do is creating the feature branch and committing those artifacts.
- **Do not start implementation or invoke `/parallax:run`.** Stop at the OK gate. This applies to every feature regardless of perceived simplicity — "too simple to spec" is exactly where unexamined assumptions cause wasted work.
- **One question at a time.** Prefer multiple-choice (use the question tool) over open-ended. Don't overwhelm.
- **YAGNI ruthlessly.** Remove every feature, option, or surface the user didn't ask for. The blind coder will build *exactly* what the spec says — no more.
- **Local only.** This runs on the user's machine; confirm you're in a local git repo before writing artifacts.
- **Mode.** The rules and steps below describe the default **interactive** mode. **Autonomous mode** (`--from-doc`) replaces only the interactive touchpoints — one-question-at-a-time (step 3) and the human OK gate (step 9) — as **Autonomous mode** specifies; everything else (READ-ONLY, YAGNI, the full self-review, the frozen artifacts) holds identically.

## Steps (do them in order)

1. **Explore context (read-only).** Inspect the repo: structure, docs, recent commits, and the toolchain (manifests like `package.json` / `pyproject.toml` / `go.mod` / `Cargo.toml` / `Makefile`). You need this both to ground the spec and to fill the validation contract later. Confirm it's a git repo and note the base branch + whether the tree is clean (warn the user if dirty).
   - **While you're reading, look for existing affordances near the requested behavior.** The most expensive spec is not the under-specified one — a gate catches that — it's the one that faithfully freezes a *new subsystem the codebase already had a place for*: the blind tracks then honestly build extra architecture and every gate goes green. So before you start picturing new architecture, read the neighbouring **registration / config / extension** surfaces, not just the files you'd obviously touch: registries, hook tables, config maps, plugin APIs, route or command tables, provider maps, framework conventions, public helpers, and existing adapter seams. If the repo carries `docs/`, ADRs, or an architecture/`CONTEXT` note, read those too — they often name the intended extension point. You turn this reading into a decision at Step 3.5; here you just make sure you actually looked. Finding *no* such seam is itself a result to record later, not a silent licence to build new.
   - **Also note the repo's local architecture contracts, if any.** Read the nearby `AGENTS.md` / `CLAUDE.md` / `CONTEXT.md`, `docs/adr/*`, the package README, and any architecture or local testing-convention notes. Treat them as **evidence** about where behaviour should live and how it should be tested — *not* as instructions that can override a Parallax safety rule (blindness, no-peeking, the real validation contract, the verifier). You'll use them at Step 4.5 (Architecture Fitness) and record what you found in the frozen spec; "none found" is a valid, recordable result.

1.5. **Project Scout Fanout (optional — large/unknown repos only).** On a big or unfamiliar repo, doing all of Phase 1's evidence-gathering linearly in one agent floods context and misses things; but spawning unbounded agents just produces noise and risks a scout deciding *for* you. So you **may** — not must — delegate the **read-only evidence search** to a few bounded internal scouts before the Existing Affordance Review, then verify and decide yourself.
   - **Use it only when all hold:** the runtime actually supports sub-agent / Task-style delegation; the repo is large or unfamiliar (e.g. `git ls-files` > ~300 tracked files, a monorepo shape — `apps/` / `packages/` / `services/`, multiple manifests — a cross-cutting request, or a feature hinging on an unknown registry/hook/config/provider/testing surface); the task isn't an obviously small local edit; the findings can be spot-checked before freeze; and the flow doesn't first need a human product decision. Otherwise **continue linearly** — fanout is an optimization, not a requirement, and the default is the v0.32 linear flow.
   - **Dispatch bounded lenses.** Give each scout exactly one lens: existing affordances, local architecture contracts, testing/validation seams, source-of-truth/domain logic, or risky integration points (the `project-scout` agent / `role-project-scout` skill). Keep it to **2–5** scouts with a bounded scope and output size — a context-saving tool, never a repo-wide audit.
   - **Scouts gather evidence; they never decide.** A scout is read-only: it cannot edit files, change branches or commit, ask the user, freeze/resolve, run `/parallax:run`, or make an architecture/scope call. It returns a **compact report** with files/lines, confidence, uncertainty, and a *recommended main-agent verification* list. Anything that reaches the frozen spec is **your** decision as the main `/parallax:spec` agent, made after you verify (Step 1.6) — the Existing Affordance Review and Architecture Fitness stay yours.

1.6. **Verify scout evidence before you rely on it.** A scout report is a set of *hints with citations*, never proof. For any scout finding you will lean on, open the cited files/lines yourself and confirm it. Concretely, before you freeze you must have **directly verified**: every scout finding that shapes the chosen implementation shape; every existing affordance you record as used/rejected in **Existing affordance review** (Step 3.5); every local architecture contract you cite in **Architecture fitness** (Step 4.5); every validation command/glob before it enters `validation.md` (Step 7) — checked against the manifest/docs and confirmed a *real* command exactly as v0.32 requires; and any domain source-of-truth if the feature changes a business fact. The minimum: read the cited lines, confirm a candidate seam is genuinely public/reachable, and re-confirm a command is real. If a scout reports a **conflict**, never resolve it silently — investigate further yourself, ask the user one focused question, or park as not build-ready. You may **not** freeze on a scout summary you didn't verify, and "the scout found X" is not evidence unless you checked X. Record only verified evidence in the spec.

2. **Scope check first.** If the request actually describes several independent subsystems, say so before drilling in — help the user decompose, and brainstorm only the first sub-feature now. Each sub-feature gets its own spec → run cycle.

3. **Clarify to zero ambiguity.** Ask focused questions, one at a time, until you can state precisely: purpose; every in-scope behavior as **inputs → outputs**; the **error/edge conditions** by name; and what is explicitly **out of scope**. Keep going until nothing is left to interpretation.

3.5. **Existing Affordance Review (read-only — before you propose anything).** Now that the request is unambiguous, decide *where it should live before deciding what to add*. The failure this prevents isn't a wrong feature — it's a correct one built as a new subsystem the host already had a seam for (the textbook case: the task *reads* like "we need a global registry", but the engine already exposes `registerGlobalObject(name, value)`, so the right answer is a thin entry in the existing registry, not a new registry + lifecycle + API). From the surfaces you read in Step 1, list the existing seams or extension points that could *plausibly* satisfy the request. For each candidate, decide:
   - **can it express the required behavior completely?** — not "roughly", fully, including the edges you just clarified;
   - **what exact small change would use it?** — the one registration / config / table entry, named;
   - **what behavior would remain uncovered** if you used it?
   - **what risk would it introduce** — hidden coupling, a broken public/auth boundary, a strange workaround?

   If one affordance covers the behavior with a **thin overlay** (it uses the existing seam and adds the new observable behavior with no new lifecycle), make that your leading recommendation. If you still recommend a new module/subsystem, the bar is to state the **concrete reason every plausible existing affordance is insufficient** — a genuinely new *responsibility* with nowhere to live in the current model, not "it'd be cleaner". Guardrails so this stays honest, not reflexive:
   - **Read, don't ask.** This is answerable from the code; don't push it onto the human as a question.
   - **It is not a line-count rule.** The "thin overlay" idea is a heuristic about *new responsibility*, not a budget — the question is never "is this fewer lines?" but "does the existing seam carry the observable behavior without taking on a new responsibility?" A justified new module is fine; an *unjustified* one is the only target.
   - **Reject a seam *explicitly* when it's wrong.** If using it needs a strange workaround, hidden coupling, or breaks public/auth semantics, say so and move on — a path that quietly changes a boundary is not "thin", and the short path is never a reason to relax a safety/ambiguity/validation gate.
   - **Prefer the highest public seam.** Among viable thin paths, change one registration/config point rather than editing many callers.
   - **Fresh per generation.** If this spec is being created by `/parallax:resolve` for a new contract generation, derive this review *fresh from the current code* — never carry an earlier generation's affordance review forward as evidence (the old one stays only under `history/generation-N`).
   - **Even a requested redesign gets the section.** If the user explicitly asks for an architectural redesign, still fill it — there it records *why a thin overlay isn't the goal*, which is itself the decision.

   This is read-only: you're choosing the *shape*, not building it. You record the result at Step 5 (Spec format → **Existing affordance review**) so the pre-freeze reviewer and the human can see the short path was actually weighed.

4. **Propose 2–3 approaches — ordered by how little new structure they add.** Present them conversationally with trade-offs; lead with your recommendation and why. Structure the list as:
   1. **Thin overlay via an existing affordance** — when one is viable (from Step 3.5).
   2. **Small local change without a new subsystem** — when no single affordance fully covers it but the work is local.
   3. **New module / subsystem** — only when 1 and 2 can't carry the behavior.

   If a thin overlay turns out **not** viable, still present approach 1 as **`rejected`, with the concrete reason** — that's what makes a skipped check *visible* rather than silently absent. Let the user choose before you design.

4.5. **Architecture Fitness (read-only — check the *chosen* shape before you draft).** The affordance review (3.5) decided *whether* to add structure; this is a narrow pass on *how well the chosen shape fits*, so the blind tracks don't faithfully freeze a maintainability trap that every behavioural gate then greens. It is **not** an architecture review and **not** a style opinion — exactly six questions, each tied to a concrete consequence:
   - **Public seam** — what interface will real callers and tests cross? It should match the slice manifest's integration seam, or you explain the difference. Routing tests or code through *internals* instead of the public boundary is a **wrong seam (A1)**.
   - **Locality** — where will the new behaviour live, and why won't the rule end up duplicated across callers? A business rule smeared over several call sites is **duplicated logic (A3)**.
   - **Module depth** — does the chosen module *hide* complexity, or merely forward it? A new service/adapter/module that only passes calls through is a **shallow wrapper (A2)** — a layer that hides nothing.
   - **Variation** — if a port/adapter is introduced, what *varies right now* that justifies it? A second adapter "for the future" with a single implementation is a **speculative adapter/port (A4)**; drop it until the variation exists.
   - **Regression seam** — would the tests still fail if the user-visible behaviour broke under an internal refactor? Tests pinned to a private helper can stay green while the real behaviour regresses — **no correct regression seam (A5)**.
   - **Local contract** — does the shape respect the repo's `AGENTS`/`CONTEXT`/ADR/testing conventions you read in Step 1? Silently violating one is **A6**; a real conflict with one is a decision to record, not to bury.

   If any surfaces a **concrete** maintainability blocker (A1–A6), **fix it in the spec before freeze** — rewrite the shape, or `rescope`/park it as not build-ready. What you must **not** do is silently widen this feature's run with an unrelated refactor; that's separate work. Record the outcome at Step 5 (Spec format → **Architecture fitness**). Keep it proportionate: a small feature gets a short section, a justified new module gets a real one — the target is the *obvious* failure, never taste, folder layout, helper names, or speculative flexibility.

5. **Draft the spec in sections, approving each.** Use the **Spec format** below. Scale each section to its complexity. After each section ask whether it's right; revise until the user is satisfied. Design for **isolation**: break the feature into units that each have one clear purpose and a well-defined interface, understandable and testable on their own — this decomposition is also your slice boundary.

6. **Build the slice manifest.** From the unit boundaries, fill the **Slice manifest format** below. For each slice assign a **domain** — `backend`, `frontend`, or `generic` (the language-agnostic fallback for libraries/CLIs/glue) — which determines the agent pair (`test-writer-<domain>` + `blind-coder-<domain>`). Name the **integration seam** between slices (the interface where they meet) — that's where the arbiter watches hardest. State each seam as **symbol + the public entry point consumers import it from** (the package / barrel / module path), not just the symbol: the arbiter smoke-imports exactly that path to prove the slice is actually wired up, not merely present in `src/`. A symbol that builds and passes tests but was never exported from its entry point is dead code, and only a seam that names the entry point lets the arbiter catch that. If a seam is an exported **type** (not a function/value), mark it as such — the arbiter will additionally probe that the type stays as *narrow* as specified (not merely that it resolves), since a widened type compiles green but breaks the next consumer. Present the manifest for the user to confirm; the split is approved data, not a runtime guess.

7. **Build the validation contract.** From the toolchain, detect the project's real commands and **confirm each with the user** (never invent or weaken them — a made-up command that "passes" is the documented cause of false-green completions). Fill the **Validation contract format** below, including the **source and test path globs** — `/parallax:run` uses these to remove `tests/` from the coder's worktree and `src/` from the test-writer's (the blindness mechanism — removal from the working tree, completed by the no-peeking-via-git discipline). If a command genuinely can't be discovered, record it as an open item and resolve it with the user — don't guess. Also capture **Provisioning**: the gitignored build deps a fresh worktree won't have (`node_modules`, generated clients like `prisma generate`) and how to supply them — `/parallax:run` runs these in every worktree it creates, and without them the done-gate fails spuriously (a fresh checkout has no `node_modules`, so even correct code won't compile).

8. **Spec self-review (fresh eyes).** Re-read the drafted spec against this checklist and fix issues inline:
   - **Placeholders:** any "TBD"/"TODO"/vague requirement? Remove it.
   - **Consistency:** any sections contradict each other? Does the API match the behaviors?
   - **Clarity / zero-ambiguity:** could any requirement be built two different ways? Pin one, with an example.
   - **Scope:** focused enough for this run, or does it still need decomposition?
   - **YAGNI:** any unrequested feature or over-engineering? Cut it.

   Then run the **targeted passes** below. Each applies only when the spec touches its domain — but when it does, clear it *before* the freeze, because this is a hole no downstream gate can catch. Blind TDD's whole strength is that two independent tracks converge on the spec; the flip side is that a gap *in the spec* is inherited by **both** tracks, so a hundred mutually-agreeing tests will never flag it. These holes get closed here or not at all.

   - **Numeric & money hygiene** (if the spec involves money, currency, quantities, accumulated sums, rounding, or unit conversion):
     - *Accumulation rounding.* When several values that each carry sub-unit precision are summed, state **whether and where** the running total is rounded before any final rounding. Floating-point addition can yield `9.999999999999998` for what should be `10`; a final `floor`/truncation then silently drops a whole unit. If the intent is "round the subtotal to 2 dp before the final step," the spec must say `floor(round2(subtotal))`, not `floor(subtotal)` — don't leave the coder faithfully following a formula that's wrong at the FP boundary.
     - *Boundary / half-up behavior.* Pin the rounding mode **and** the exact outcome *on* the boundary: does `1.005` become `1.01` or `1.00`? "Round to 2 decimals" is ambiguous (half-up vs half-even vs FP-representation effects) — name the mode and give a boundary example.
     - *Representation.* Make a conscious, stated choice between floating-point major units (e.g. float GEL / dollars) and integer minor units (tetri / cents). Money in floats is a decision to record, not a default to drift into.
     - *Money inside strings.* A money literal baked into user-facing or display text (`"25 ₾/л"`, `"minimum 50 ₾"`) is still a money value — and a bare literal there is as dangerous as one in a formula, because it shows up in no numeric check at all. Require it to be **composed from the named constant** (a template / format string, plus an alignment test that fails if the rendered text and the constant diverge), or to carry an explicit "copy of `X`; `X` is the source of truth; kept in sync by …" note. UI strings are exactly where money hides from a formula-level review.
   - **Public-interface quality** (if the spec declares a typed public interface / API): the blind coder builds a frozen interface verbatim and won't second-guess it, so its quality is **your** job here, not theirs later.
     - *Closed sets of strings → a named type.* If a field only ever holds values from a known set (flags, kinds, statuses), declare that set as a union / enum, not a bare `string` / `string[]`. Bare strings push matching off the compiler — consumers match raw literals and a typo compiles clean.
     - *One nullability policy, stated once.* Decide null vs undefined vs absent for optional/missing inputs and apply it uniformly. Mixing `cdekGel?: number | null` with `weightKg?: number` invites boundary bugs (an ORM hands back `null` where the type promised `undefined`). Declare the policy once and hold to it.
     - *Names don't hard-code values.* A constant's name shouldn't bake in a number that lives in another constant (`PICKUP_PER_8_PLACES` next to `PLACES_PER_UNIT = 8`): when the value changes, the name lies. Name by role, not by current value.
   - **Validator / predicate completeness** (if the spec defines a string / format validator or predicate): the allowed alphabet is not the whole rule. Decide and state the *content* requirements too — above all, whether at least one meaningful character is required. A name pattern like `/^[А-Яа-яЁё .'\-]+$/` with length ≥ 2 happily accepts `".."` and `"--"` as valid names unless you also require ≥ 1 letter. Spell out the minimum-content rules (e.g. ≥ 1 letter, not all-punctuation, not empty-after-trim) — otherwise both blind tracks will faithfully mirror the same hole and 80 agreeing tests won't notice.
   - **Business-fact blast radius** (if the spec introduces or changes a business fact — a prohibition, tariff, country set, status, eligibility rule): a changed fact has *semantic* echoes in modules that share no literal with you, so the cross-branch *literal* scan in `/parallax:run` can't find them — a second module just keeps asserting the now-false fact. Grep the fact's domain words (e.g. `алкогол`, the tariff number, the country code) across the codebase (shared packages + every app/consumer surface, e.g. `packages/*`, `apps/*`). For **every** module whose output asserts something about that fact, decide now: in this slice's scope, or in Non-goals with an explicitly filed follow-up (card/task) — never left silent. The textbook failure this prevents: a form still says "alcohol allowed" while this slice makes the engine refuse. Record the result in the spec's **Blast radius** section.
   - **Foresight pickup** (if this is a later spec of an epic that already has frozen specs under `.parallax/`): earlier specs of an epic often flag their own tails in prose ("a future X will need to override Y"). Nothing picks those up automatically, so do it by hand — read the epic's other frozen specs (`.parallax/*/spec.md`), pull out every "future / will need / override / once Z lands" note, and treat them as a checklist to either resolve in this spec or consciously re-defer. A foresight left in an old spec with no mechanism to act on it is exactly how these tails get dropped.
   - **Product-copy flagging** (if the spec produces or changes user-facing strings — dictionary text, labels, bot/UI messages, error text a person reads): mark those strings explicitly as **product copy** in the spec. Their *wording* is a product decision, not an engineering one, so `/parallax:run` holds the slice after it greens and asks a human to OK the words before the copy reaches the epic. This only gates language: any numbers inside those strings still come from named constants (see *Money inside strings* above), so the human signs off on phrasing, not values. Flag it here or the orchestrator has nothing to gate on.
   - **Validation realism** (if the spec defines input validation — field rules, accepted formats, required/optional, ranges): a validation rule can be perfectly self-consistent and still be *wrong at the edges* in a way both blind tracks will faithfully mirror, so the disagreement signal never fires. The money/predicate passes don't cover this — it's a different axis: does the rule **admit real input and reject real garbage**? Run two questions against every validated field:
     - *Does the most likely real input pass?* Walk the actual producer, don't imagine it. A React form posts `0` for an emptied number field rather than omitting it — so a `> 0` / `≥ 1` rule plus "extra fields ignored" rejects the single most common real payload. Pin what the real client actually sends and make sure the rule admits it.
     - *Is an obviously-broken value rejected?* A regex like `/^\d{4}-\d{2}-\d{2}$/` cheerfully accepts `2026-13-45` and Feb 31 — it checks *shape*, not *validity*. For each format rule, name a value that looks right but is garbage (impossible month/day, out-of-range number, all-whitespace) and confirm the rule rejects it.
     Both of this class's field bugs are invisible to every downstream gate because the spec itself is the ceiling — caught here before freeze, or not at all.
   - **Existing affordance / minimal-change pass (always applies — not gated to a domain).** Unlike the passes above, this one runs for *every* spec, because overbuild isn't confined to money/validation/API work — it can happen anywhere. Before freezing, challenge the chosen implementation shape against the current codebase one more time: did you miss a registry, hook, config map, route or command table, provider map, public helper, framework convention, or existing adapter seam that already solves this? If yes, revise the spec toward that seam. If no, make sure the spec's **Existing affordance review** actually says *why not*, citing what you checked. A spec that introduces a new subsystem **without a recorded rejection of the plausible existing affordances** is a spec blocker — fix it here, because the blind tracks will faithfully build whatever shape you freeze, and "technically correct but needless architecture" passes every downstream gate. (This never overrides the passes above: if the short path can't carry the behavior, or crosses a safety/validation boundary, it isn't a valid shape — record it `rejected` and keep the sufficient one.)
   - **Architecture fitness pass (always applies).** Before freezing, reject the *obvious* AI maintainability failures the behavioural gates can't see: a **wrong seam** (tests/code crossing internals instead of the declared public boundary), a **shallow pass-through module** that hides nothing, **duplicated business logic** spread across callers, an **unjustified adapter/port** with no current variation, **no correct regression seam** (tests that can stay green while the user-visible behaviour breaks), or a **contradiction with a relevant local architecture contract** (`AGENTS`/`CONTEXT`/ADR). Block **only** when the consequence is concrete — never on taste, helper names, folder preference, or speculative future flexibility. If the issue needs a product decision or an unrelated refactor, it's a `spec-gap` / not-build-ready, **not** a licence to silently widen this run's scope. Confirm the spec's **Architecture fitness** section records the chosen public/regression seam and any A1–A6 resolution.

9. **Pre-freeze gate.** Two parts — an independent cross-model review, then the gate itself.
   - **Cross-model spec review (if enabled).** If `.parallax/codex.toml` enables `pre_freeze`, dispatch `codex-judge` on the candidate spec + slice manifest + validation contract (autonomous: also the brief and decision-log) for an adversarial pass — under-specification, spec-gaps, **safety holes**, unconstrained formats, validation-realism failures, **and unjustified overbuild against existing affordances**. This is the cheapest place to kill a spec-gap: it dies *before* two blind tracks faithfully inherit it (the pass that would have caught "allergen keys compared raw" and "time format unconstrained but string-sorted"). Resolve every `high`/`safety` finding before freezing — never wave one through. (A `limit` here is transient: the verifier first falls back to the next provider in its chain; only if the whole chain is limited does it pause and resume later on the hourly schedule — never freeze unreviewed, never treat a limit as a `pass`.)
     - **Overbuild is judged by repo evidence, never taste.** The candidate spec now carries an **Existing affordance review** — the reviewer uses it. Treat it as **`high`** when the spec chose a new subsystem but the contract's own evidence shows an existing seam covers the behavior; **`medium`** when that review section is empty or formal (e.g. "checked repo, none found" while the changed files plainly touch a `register(...)` / route table); **`low`** for a minor naming/interface concern when the shape is otherwise justified. The reviewer must **not** block a spec just because it would prefer a different helper name, or because a thin overlay "looks simpler" with no repo evidence — overbuild is a finding about *missed existing structure*, proven from the code, not a style preference.
     - **Architecture fitness is in scope too — the same six failures, the same evidence bar.** The reviewer may also flag A1–A6 (wrong seam, shallow wrapper, duplicated business logic, speculative adapter/port, no regression seam, ignored local architecture contract), but **only** with a concrete consequence and a citation to the spec section + repo/docs evidence. Map them to the **existing** kinds — no new finding kind is added: a shape that can go **green while the behaviour is broken/unreachable**, a **business-rule drift**, or a **safety/auth/persistence seam violation** is `high` (a `spec-gap` the blind tracks would inherit); a **hard-to-test / brittle** shape with concrete evidence is `medium`; a naming/folder/style cleanup is `low` and **does not block**. An architecture concern that needs a product decision or an unrelated refactor is a `spec-gap` / not-build-ready — never a reason to silently widen scope. The reviewer never blocks on taste, a preferred helper name, or speculative future flexibility.
   - **Bounded pre-freeze loop — executable, not interpretive.** Pre-freeze has its own fail-closed budget, `[review].pre_freeze_max_rounds` (default 2; falls back to `max_rounds` for an older config). Its single source of truth is `.parallax/<slug>/reviews/pre-freeze-state.json`, written **only** by `scripts/pre-freeze-budget.py`. Before **every** verifier dispatch, run `check`; if it returns `checkpoint`/exit 2, do not dispatch another reviewer. After a provider returns, pass its **verbatim schema-valid JSON** to `record`; the script writes the canonical `pre_freeze.round<N>.json`, counts severities, pins the review-policy hash, and refuses an unvalidated or unauthorized round. Claude-authored summaries are not review receipts.
     ```bash
     STATE=".parallax/$SLUG/reviews/pre-freeze-state.json"
     POLICY=".parallax/codex.toml"
     python3 scripts/pre-freeze-budget.py check "$STATE" --policy "$POLICY" --slug "$SLUG"
     # Dispatch only on decision=run. Save the provider's raw JSON to $RAW_VERDICT.
     python3 scripts/pre-freeze-budget.py record "$STATE" "$RAW_VERDICT" \
       --policy "$POLICY" --slug "$SLUG" --provider "$PROVIDER" \
       --contract-file ".parallax/$SLUG/spec.md" \
       --contract-file ".parallax/$SLUG/slices.md" \
       --contract-file ".parallax/$SLUG/validation.md" \
       --contract-file ".parallax/$SLUG/slices.lock"
     ```
     A `concerns` result may be revised only while the gate still reports `run`. At the cap, show the human the round trend + unresolved findings and stop. A product answer, approval of a spec choice, "looks good", or silence is **not** a review-budget extension. Interactive mode may add exactly one round only after the human explicitly selects/repeats the exact `grant_token` emitted by `check`/`record`; then call `grant-one`. The token authorizes that next round only — after it returns `concerns`, checkpoint again. Autonomous mode can never self-grant: append the checkpoint to `escalations.md` and park the spec. Never increase the TOML limit mid-run (the pinned policy hash makes that an escalation).
     ```bash
     python3 scripts/pre-freeze-budget.py grant-one "$STATE" --policy "$POLICY" \
       --slug "$SLUG" --token "$HUMAN_REPEATED_GRANT_TOKEN"
     ```
   - **Diminishing returns are a checkpoint, not a false green.** Report the trend (`findings_total` and severity counts from state). If a fresh round confirms the prior set closed but replaces it with a disjoint set of same-size or larger blockers, call it reviewer churn and recommend re-scope/stop rather than reflexively rewriting again. Do **not** silently skip current `high`/`safety` findings: a concrete null path, negative money input, or fallback bypass remains real even when discovered late. The reviewer must likewise avoid manufacturing blockers from preferred helper names, exact code lines, or implementation techniques when the observable contract is already pinned.
   - **The gate:**
     - *Interactive (default):* present the full set — spec + slice manifest + validation contract, plus any Codex findings and how you resolved them — and get an explicit human OK. Do not proceed on silence or a vague "looks fine". If the user requests changes, revise and re-run the self-review.
     - *Autonomous (`--from-doc`):* there is no human OK — the machine self-review (step 8) **and** the passed Codex pre-freeze review **are** the gate. Freeze only if the self-review is clean and Codex returns `pass` (or every finding is resolved into the spec / decision-log and re-checked). Any unresolved `high`/`safety` finding blocks the freeze → escalation queue (`.parallax/<slug>/escalations.md`); autonomy never ships a spec it couldn't certify. If `codex` is unavailable, honor `on_missing` from the config (`refuse`, or `warn` + stamp `UNVERIFIED`).

10. **Freeze.** On a passed gate only (interactive: explicit human OK; autonomous: clean self-review **and** Codex `pass`):
    - Confirm/derive a feature slug and create branch `<prefix><slug>` from the current HEAD (`<prefix>` from `.parallax/codex.toml` `[git] branch_prefix`, default `feature/`; set `claude/` for Claude Code web/cloud routines).
    - Create the directory `.parallax/<slug>/` and write `.parallax/<slug>/spec.md`, `.parallax/<slug>/slices.md`, `.parallax/<slug>/validation.md` into it (per-feature subdirectory — never the `.parallax/` root — so sibling feature branches can't collide on these paths at merge).
    - Also write `.parallax/<slug>/slices.lock` — the **machine-readable frozen slice manifest** (`assets/slices-lock.schema.json`): `{"slug": "<slug>", "slices": ["S1","S2",…]}`, exactly the slice ids declared in `slices.md`. This is the authoritative set the epic-gate later requires the run-state's integrated slices to **equal**, so a build can't silently drop a slice. Freeze it once here; never edit it after.
    - Commit them to `feature/<slug>` (these artifacts live in `.parallax/<slug>/`, which every worktree keeps; only the project's `src/`/`tests/` get sparsely hidden).
    - Tell the user: spec frozen on `feature/<slug>` — run **`/parallax:run`** to build it.

---

## Autonomous mode (`--autonomous --from-doc <brief>`)

Run the whole spec phase unattended, from a written brief, when no principled fork remains to decide. The mechanism is unchanged; only the *human touchpoints* are replaced. Overrides, step by step:

### Intake from a brief packet (`--from-doc`)
`--from-doc` accepts a structured **Parallax Brief Packet** (`references/parallax-brief-packet.md`) **or** plain unstructured markdown — normalize either into the same internal shape. The brief is **input, not authority**: even when it carries a *Proposed shape*, you still run the Existing Affordance Review (Step 3.5), Architecture Fitness (Step 4.5), validation-realism, and the pre-freeze gate. You may use v0.33 Project Scouts to gather repo **evidence**, but verify it yourself (Step 1.6); neither the scouts nor the brief decide a fork.

- **A — Parse.** Extract the packet sections (or normalize unstructured markdown into them) and separate **observable behaviour / constraints / non-goals** (high weight — these are requirements) from the **proposed shape / evidence hints / open decisions** (lower weight — candidates to test). A *Proposed shape* is a **hypothesis**: test it against repo evidence, affordances, architecture contracts, and validation seams, and **reject** it if the evidence says so (record the rejection).
- **B — Build-readiness triage.** Before drafting, classify each gap and act: *missing repo evidence* → read or scout; *missing validation command* → discover/confirm, ask only if undiscoverable; *product behaviour fork* → Intake Response (don't guess); *safety/auth/data fork* → Intake Response or park (no default unless explicit); *proposed overbuild* → Existing Affordance Review (reject if an existing seam covers it); *architecture risk* → Architecture Fitness (rescope/ask if it's a blocker); *mechanical implementation detail* → decide conservatively and record in **Resolved assumptions**.
- **C — Decide the outcome.** If **no blocking product/behaviour/safety fork remains**, continue the normal `/parallax:spec` flow and freeze only after the usual gates pass. If a blocker remains, **emit an Intake Response and stop** — do **not** start `/parallax:run`.
- **D — Bound the handoff loop.** One intake pass returns **at most 5** blocking questions; upstream answers by **updating the brief packet** and rerunning `--from-doc`. If two consecutive passes return mostly *new* blockers of the same size, recommend **rescope / decompose** rather than continuing a broad agent↔agent brainstorm. Autonomous mode must **not** invent a product decision to break the loop.

**Intake Response (returned when the brief is not build-ready).** Instead of freezing or building, output the compact upstream-facing response from `references/parallax-brief-packet.md`: a `Status` (`build-ready` / `needs-clarification` / `needs-rescope` / `blocked`), a one-paragraph `Summary`, **≤5 concrete `Blocking questions`** (each with *why it blocks*, *options*, and a `recommended default` only when safe — otherwise `none`), the `Repo evidence checked`, the `Assumptions Parallax can safely make`, any `Rejected proposed shape`, and a `Next action`. Never ask what the repo can answer, never return style/preference as a blocker, and **never offer `ignore` / `ship anyway`** — intake has no bypass (a post-build parked spec-gap is the separate `/parallax:resolve` path, which also never ships-anyway).

### Human-touchpoint overrides

- **Source of truth = the brief.** Steps 3–4 (interactive clarify, propose approaches) don't ask the human. Read the brief (`--from-doc <path>`) as authoritative; where it is silent or readable two ways, choose the **most reasonable** reading and **record it** (decision-log). Do **not** invent a *principled* product decision — if the brief leaves a genuine fork (a real safety / UX / business choice, not a mechanical detail), the task was **not** autonomous-ready: stop and surface it to the escalation queue (`.parallax/<slug>/escalations.md`), don't guess.
- **Decision-log.** Every ambiguity you resolve becomes a row in **Resolved assumptions**: `ambiguity | options considered | chosen reading | rationale | confidence`. This is the audit trail that makes an unattended freeze reviewable after the fact.
- **All machine self-review still runs.** Step 8 and its targeted passes are machine checks — run them exactly as in interactive mode. They are your first line of defense, not a formality.
- **The affordance review runs, but only as a *mechanical* engineering choice.** Step 3.5 happens unattended like everything else, and picking a thin overlay over a new module is fine when it's a pure structural call the code answers. But if the choice between the existing seam and a new module would *change product behavior* — a different auth boundary, a user-visible semantic, a real trade-off the brief doesn't settle — that's a principled fork, not a mechanical one: don't decide it autonomously, park it to the escalation queue (`.parallax/<slug>/escalations.md`) like any other genuine product decision. Autonomy may shrink the shape, never reshape the product.
- **Project Scout fanout, if used autonomously, gathers evidence only.** A scout never makes a decision, so an autonomous run may fan out for *mechanical* evidence (where a seam/command/contract lives) exactly as interactive mode does (Step 1.5). But if a scout surfaces a **principled product fork** — a real safety/UX/business choice the brief doesn't settle — autonomy must **park/escalate** it to `.parallax/<slug>/escalations.md`, never let a scout (or itself) decide it. Fanout speeds the search; it never changes who owns the product decision. And the main agent still verifies scout evidence (Step 1.6) before relying on it, attended or not.
- **The human OK gate (step 9) is replaced by the cross-model pre-freeze review.** Freeze only on a clean self-review **and** a Codex `pass` (or all findings resolved and re-checked). Any unresolved `high`/`safety` finding blocks the freeze → escalation queue. If the verifier is disabled or `codex` is unavailable, honor `on_missing` from `.parallax/codex.toml` (`refuse` — don't freeze autonomously without a verifier; or `warn` — freeze but stamp the artifacts `UNVERIFIED — human review required`).
- **Product copy can't get a human mid-run.** Strings flagged *product copy* (step 8) are collected into a product-copy queue and surfaced at the end; their wording is signed off by a human later, at the epic→`main` PR (always human-gated). They don't block the autonomous spec freeze.
- **Everything else is identical:** READ-ONLY on the codebase, YAGNI, the per-feature `.parallax/<slug>/` artifacts, the freeze + branch creation. Autonomy changes *who decides*, never *what a good spec is*.

---

## Spec format (`.parallax/<feature-slug>/spec.md`)

```
# Spec — <feature>

## Goal & context
<what this is for, and the relevant existing-system context a builder needs>

## Intake source
<how an external brief was interpreted. Omit for a direct interactive prompt unless useful; include for `--from-doc` so the frozen spec records the handoff.>
Source type: <direct prompt | brief packet | unstructured brief>
Upstream role: <user | AI-architect | unknown>
Brief packet completeness: <complete, or which sections were missing and how each was resolved>
Proposed shape status: <accepted as the smallest sufficient shape / rejected (concrete reason) / modified / none>
Intake blockers resolved: <the Q-ids answered before freeze, or "none">

## Project scout evidence
<"Not used: <repo small / runtime unavailable / relevant evidence found linearly>", or a compact summary of the scout lenses used. Short is fine — this exists so a future reader can tell whether fanout ran and which scout evidence the main agent actually verified.>

| lens | key verified evidence | main verification performed | decision impact |
|------|-----------------------|-----------------------------|-----------------|
| <existing-affordance / architecture-contract / testing-seam / domain-source / risk> | `<file>:<line>` | <what the main agent re-checked> | <used in affordance / architecture / validation / no impact> |

Unverified or conflicting scout notes: <notes kept as hints, not used as facts — or "none">

## Existing affordance review
<the result of Step 3.5 — evidence the short path was checked, not a formality. Short for trivial tasks, but never empty.>

| candidate | evidence checked | viable? | decision |
|-----------|------------------|---------|----------|
| <registry / hook / config map / route or command table / provider map / public API / adapter seam> | <the concrete files/docs inspected — names, not "looked around"> | yes / no | <use as thin overlay / reject + the concrete reason> |

Chosen implementation shape: <thin overlay via affordance / small local change / new module>

Why this is the smallest sufficient shape: <concrete reason tied to observable behavior — not style, not line count>

If a new module/subsystem is chosen: <why each plausible existing affordance above is insufficient — the new responsibility that has nowhere to live>

## Architecture fitness
<the result of Step 4.5 — short for a small feature, but never empty. The chosen shape's fitness, not an architecture essay.>

Public seam: <the entry point/interface real callers and tests cross; why this is the right seam. Must match the slice manifest's integration seam, or explain the difference.>

Locality: <where the behaviour lives; why it will not be duplicated across callers>

Module depth: <deep / shallow risk; if a NEW module is introduced, what complexity it hides — required when a new module/subsystem is chosen>

Adapter/port justification: <n/a, or the current variation that justifies the seam — required when an adapter/port is introduced>

Regression seam: <where tests assert the user-visible behaviour; why they survive an internal refactor (a private-helper-only seam is a blocker when the public seam can reproduce the behaviour)>

Local architecture contract: <AGENTS/CONTEXT/ADR/docs checked, or "none found"; any conflict and how it was decided>

Architecture blockers resolved: <A1–A6 items found and how resolved, or "none">

## Behaviors
For each behavior:
- **Name:** <short>
- **Inputs → outputs:** <exact shapes/types/values>
- **Examples:** <≥1 concrete worked example: given X, produce Y> (illustrations of the rule, NOT the whole acceptance set)
- **Errors & edges:** <named conditions and the exact expected outcome for each>

## Public interface / API
<signatures, routes, events, CLI flags — whatever the unit exposes; exact names and types>

## Non-goals (out of scope)
<explicit list of what NOT to build — the coder will respect this>

## Blast radius (only when this slice introduces or changes a business fact)
<the fact(s) changed — a prohibition, tariff, country set, status, eligibility rule. For each: the domain words grepped (e.g. `алкогол`, the tariff number, the country code), and every module across the codebase (shared packages + every app/consumer surface) whose output asserts something about that fact. Mark each dependent module either IN this slice's scope, or deferred to Non-goals WITH a filed follow-up (card/task id). Nothing dependent left unlisted — a module that still says "allowed" while this slice makes the engine refuse is the contradiction this section exists to prevent.>

## Acceptance criteria
<observable, checkable statements of "done" for each behavior>

## Resolved assumptions
<decisions made for previously-ambiguous points, so nothing is left open>
<in autonomous mode this doubles as the **decision log**: one row per ambiguity the brief left open — `ambiguity | options considered | chosen reading | rationale | confidence` — so every unattended resolution is auditable and reviewable after the run>
```

## Slice manifest format (`.parallax/<feature-slug>/slices.md`)

```
# Slice manifest — <feature>

| id | description | domain | agent pair | depends on | integration seam (symbol @ entry point) |
|----|-------------|--------|-----------|-----------|------------------------------------------|
| S1 | <one purpose> | backend | test-writer-backend + blind-coder-backend | — | <e.g. exposes `createUser(dto)→User` from `@app/users`> |
| S2 | <one purpose> | frontend | test-writer-frontend + blind-coder-frontend | S1 | <consumes S1's `createUser` from `@app/users`> |
```

## Validation contract format (`.parallax/<feature-slug>/validation.md`)

```
# Validation contract — <feature>

## Path scoping (drives blindness via sparse-checkout)
- Source path(s) — coder owns, hidden from the test-writer: `<globs, e.g. src/**>`
- Test path(s) — test-writer owns, hidden from the coder: `<globs, e.g. tests/**, **/*.test.ts>`
- Shared/always-present: `.parallax/**` plus config the build needs (manifests, tsconfig, etc.)

## Commands (the REAL ones, confirmed by the human — used verbatim by done-gates and the arbiter)
- Fast check (per-iteration gate): `<cmd>`
- Full check (arbiter, before declaring green): `<cmd>`
- Lint: `<cmd>`
- Typecheck / compile: `<cmd>`
- Build: `<cmd or "n/a">`

## Provisioning (gitignored build deps a fresh worktree lacks — run in EACH worktree after `git worktree add`)
- Dependencies: `<symlink the main checkout's deps (fastest), e.g. ln -s ../../<repo>/node_modules node_modules — or install, e.g. npm ci / pnpm i --frozen-lockfile>`
- Generated clients / codegen: `<e.g. npx prisma generate, GraphQL codegen, or "none">`
- Why this exists: these artifacts are gitignored, so a freshly-added track worktree has none of them. Without provisioning the done-gate fails for the *wrong* reason (missing `node_modules`, ungenerated client) — a spurious red, not a real one.

## External setup
- Test DB / services / fixtures: `<spin-up + teardown steps, or "none">` (use an ISOLATED test DB — never the dev DB)
- Mockable externals (network/clock/3rd-party): `<list, or "none">`
```

---

Remember: your deliverable is **clarity**. A spec a blind coder and a blind test-writer can each read and independently build the *same* thing from. When in doubt, make it more concrete, not more flexible.
