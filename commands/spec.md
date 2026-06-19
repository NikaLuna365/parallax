---
name: spec
description: "Phase 1 of the Parallax pipeline. Drive a READ-ONLY interactive brainstorm into ONE maximally-concrete spec with zero open questions, plus a slice manifest and a real validation contract, then freeze them at a gate — a human OK, or in autonomous mode (--from-doc) a machine self-review plus an independent Codex pre-freeze review. Run this before /parallax:run."
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

2. **Scope check first.** If the request actually describes several independent subsystems, say so before drilling in — help the user decompose, and brainstorm only the first sub-feature now. Each sub-feature gets its own spec → run cycle.

3. **Clarify to zero ambiguity.** Ask focused questions, one at a time, until you can state precisely: purpose; every in-scope behavior as **inputs → outputs**; the **error/edge conditions** by name; and what is explicitly **out of scope**. Keep going until nothing is left to interpretation.

4. **Propose 2–3 approaches.** Present them conversationally with trade-offs; lead with your recommendation and why. Let the user choose before you design.

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

9. **Pre-freeze gate.** Two parts — an independent cross-model review, then the gate itself.
   - **Cross-model spec review (if enabled).** If `.parallax/codex.toml` enables `pre_freeze`, dispatch `codex-judge` on the candidate spec + slice manifest + validation contract (autonomous: also the brief and decision-log) for an adversarial pass — under-specification, spec-gaps, **safety holes**, unconstrained formats, validation-realism failures. This is the cheapest place to kill a spec-gap: it dies *before* two blind tracks faithfully inherit it (the pass that would have caught "allergen keys compared raw" and "time format unconstrained but string-sorted"). Resolve every `high`/`safety` finding before freezing — never wave one through. (A `limit` here is transient: the verifier first falls back to the next provider in its chain; only if the whole chain is limited does it pause and resume later on the hourly schedule — never freeze unreviewed, never treat a limit as a `pass`.)
   - **The gate:**
     - *Interactive (default):* present the full set — spec + slice manifest + validation contract, plus any Codex findings and how you resolved them — and get an explicit human OK. Do not proceed on silence or a vague "looks fine". If the user requests changes, revise and re-run the self-review.
     - *Autonomous (`--from-doc`):* there is no human OK — the machine self-review (step 8) **and** the passed Codex pre-freeze review **are** the gate. Freeze only if the self-review is clean and Codex returns `pass` (or every finding is resolved into the spec / decision-log and re-checked). Any unresolved `high`/`safety` finding blocks the freeze → escalation queue (`.parallax/<slug>/escalations.md`); autonomy never ships a spec it couldn't certify. If `codex` is unavailable, honor `on_missing` from the config (`refuse`, or `warn` + stamp `UNVERIFIED`).

10. **Freeze.** On a passed gate only (interactive: explicit human OK; autonomous: clean self-review **and** Codex `pass`):
    - Confirm/derive a feature slug and create branch `<prefix><slug>` from the current HEAD (`<prefix>` from `.parallax/codex.toml` `[git] branch_prefix`, default `feature/`; set `claude/` for Claude Code web/cloud routines).
    - Create the directory `.parallax/<slug>/` and write `.parallax/<slug>/spec.md`, `.parallax/<slug>/slices.md`, `.parallax/<slug>/validation.md` into it (per-feature subdirectory — never the `.parallax/` root — so sibling feature branches can't collide on these paths at merge).
    - Commit them to `feature/<slug>` (these artifacts live in `.parallax/<slug>/`, which every worktree keeps; only the project's `src/`/`tests/` get sparsely hidden).
    - Tell the user: spec frozen on `feature/<slug>` — run **`/parallax:run`** to build it.

---

## Autonomous mode (`--autonomous --from-doc <brief>`)

Run the whole spec phase unattended, from a written brief, when no principled fork remains to decide. The mechanism is unchanged; only the *human touchpoints* are replaced. Overrides, step by step:

- **Source of truth = the brief.** Steps 3–4 (interactive clarify, propose approaches) don't ask the human. Read the brief (`--from-doc <path>`) as authoritative; where it is silent or readable two ways, choose the **most reasonable** reading and **record it** (decision-log). Do **not** invent a *principled* product decision — if the brief leaves a genuine fork (a real safety / UX / business choice, not a mechanical detail), the task was **not** autonomous-ready: stop and surface it to the escalation queue (`.parallax/<slug>/escalations.md`), don't guess.
- **Decision-log.** Every ambiguity you resolve becomes a row in **Resolved assumptions**: `ambiguity | options considered | chosen reading | rationale | confidence`. This is the audit trail that makes an unattended freeze reviewable after the fact.
- **All machine self-review still runs.** Step 8 and its targeted passes are machine checks — run them exactly as in interactive mode. They are your first line of defense, not a formality.
- **The human OK gate (step 9) is replaced by the cross-model pre-freeze review.** Freeze only on a clean self-review **and** a Codex `pass` (or all findings resolved and re-checked). Any unresolved `high`/`safety` finding blocks the freeze → escalation queue. If the verifier is disabled or `codex` is unavailable, honor `on_missing` from `.parallax/codex.toml` (`refuse` — don't freeze autonomously without a verifier; or `warn` — freeze but stamp the artifacts `UNVERIFIED — human review required`).
- **Product copy can't get a human mid-run.** Strings flagged *product copy* (step 8) are collected into a product-copy queue and surfaced at the end; their wording is signed off by a human later, at the epic→`main` PR (always human-gated). They don't block the autonomous spec freeze.
- **Everything else is identical:** READ-ONLY on the codebase, YAGNI, the per-feature `.parallax/<slug>/` artifacts, the freeze + branch creation. Autonomy changes *who decides*, never *what a good spec is*.

---

## Spec format (`.parallax/<feature-slug>/spec.md`)

```
# Spec — <feature>

## Goal & context
<what this is for, and the relevant existing-system context a builder needs>

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
