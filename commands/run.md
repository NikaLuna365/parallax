---
name: run
description: "Phase 2-5 of the tdd pipeline. From a frozen .tdd/ spec, build each slice with a blind test-writer + blind coder in parallel, validate-and-loop through the arbiter until green, then push the feature branch. Run /tdd:spec first."
argument-hint: "[feature-slug]   [--autonomous]  [--parallel]   [--resume]"
---

# /tdd:run — build the frozen spec, blind + arbitrated, then push

You are the **orchestrator** for Phase 2-5. You author **no code and no tests** — you set up git, dispatch the blind workers and the arbiter, route their results, and manage the branch. Workers and the arbiter do all authoring/judging via their own skills.

## The blindness model (why the git dance exists)

- The **coder** works in a worktree whose branch has **no test files** — it cannot teach-to-the-test because it cannot see the tests.
- The **test-writer** works in a worktree whose branch has **no source files** — it tests the spec, not an implementation, and creates its own throwaway stub to watch tests fail.
- The **integration tree** (the real `feature/<slug>`) is assembled by pulling **real `src/` from the code branch + real `tests/` from the test branch**. Only the **arbiter** sees this whole. Only the arbiter's **natural-language** analysis ever crosses back to a worker — never raw test code to the coder, never raw implementation to the test-writer.

## Step 0 — Preflight

1. Resolve the slug: use `$ARGUMENTS` if given, else the current `feature/<slug>` branch. **If `--resume` is passed (or a `.tdd/<slug>/run-state.json` with status `paused-on-limit` exists), this is a RESUME:** load that checkpoint and continue from it per *Limits, checkpointing & resume* — skip the fresh dispatch for already-`integrated` slices. Otherwise start fresh and create the checkpoint.
2. `git switch feature/<slug>`. Confirm `.tdd/<slug>/spec.md`, `.tdd/<slug>/slices.md`, `.tdd/<slug>/validation.md` exist (per-feature subdirectory, not the `.tdd/` root). If not → tell the user to run `/tdd:spec` first and stop.
3. Confirm a clean working tree and that this is a local repo (`git rev-parse --show-toplevel`). Read the three artifacts. From `.tdd/<slug>/validation.md` extract: `SRC_GLOBS`, `TEST_GLOBS`, and the commands (fast, full, lint, typecheck, build) + external setup. From `.tdd/<slug>/slices.md` extract the ordered slice list with each slice's domain and dependencies.
4. Order the slices by dependency (topological). You will process them **one at a time**; within a slice the two tracks run **in parallel**.
5. **Cross-branch value scan (catch duplicated business values before they merge).** The blind tracks each build from `main` independently, so neither can see a value that already lives as a named constant on a *sibling* feature branch of the same epic — but once both branches merge, the same tariff/threshold sitting as a bare literal here and a named constant there will silently drift the moment someone edits one. You are the only party that sees across branches, so check now, before dispatching:
   - Pull the salient business values out of `.tdd/<slug>/spec.md` — money amounts, rates, thresholds, fixed quantities, and named sets/enums.
   - Grep each across `main` and the other live feature branches of the epic:
     ```bash
     SIBLINGS=$(git branch --format='%(refname:short)' | grep '^feature/' | grep -v -- "$SLUG")
     for B in main $SIBLINGS; do
       git grep -n -F -- "<value>" "$B" 2>/dev/null && echo "   ^ found on $B"
     done
     ```
   - A hit on a sibling branch means the value already has a home. **Stop and ask the lead** how to reconcile: import the existing constant (preferred), or — if the duplication is deliberate (e.g. a display string that copies a price) — record in the spec which side is the source of truth and how the two stay in sync. Don't dispatch the slice until it's resolved; a duplicated literal is a post-merge bug no per-branch gate can catch, because both branches are green in isolation.
6. **Base provenance check (trust the base only if it really contains what it claims).** A feature usually branches not from `main` but from an integration/epic base meant to already contain earlier features of the epic. That base can silently be missing commits two ways, and a green run reveals neither (validation only checks what's in the tree): it was assembled by **copying content** instead of merging real tips, or the **local** epic ref has **lagged origin** — when a branch is checked out in another session's worktree, git won't fast-forward it on fetch/push, so your local `<epic>` can sit behind `origin/<epic>` by whole slices. Either way a fix that lived only in a dropped or un-pulled commit is gone *with its regression test*. So pin the base to the remote and verify it, before dispatching:
   - **Take the base from origin, never the local ref.** `git fetch origin <epic>` and set the cycle base = `origin/<epic>`. The local `<epic>` ref is only a cache and may be stale (see above) — never build a cycle on it directly.
   - With the lead, list the prior feature tips that base is supposed to incorporate (the live `feature/*` siblings from step 5 are your candidates). For each, assert it is an ancestor of the **remote** base:
     ```bash
     git fetch origin "<epic>"
     BASE="origin/<epic>"
     git merge-base --is-ancestor "<prior-feature-tip>" "$BASE" \
       || echo "MISSING: <prior-feature-tip> is not an ancestor of $BASE"
     ```
   - Any `MISSING` → first consult the **known-deviations registry** `.tdd/provenance-exceptions.md` (epic-level, at the `.tdd/` root — deliberately *not* per-feature; provenance spans the whole epic). Each row records a tip that is legitimately a non-ancestor and why it's safe: `<tip> | reason | compensated-by <commit> | content verified by <who/how> | date`. 
     - **Listed** (with a recorded compensation *and* verification) → report it as a **known exception (see registry)** and continue. The archaeology was already done once; don't redo it by hand every run.
     - **Not listed** → **stop and escalate to the human.** The base may be poisoned (built by copy/rebuild, or the local ref was stale); a green here would be meaningless, and the fix is to rebuild the base by *merging* the real tips into `origin/<epic>` — not to proceed. Once the human confirms it's a benign, compensated deviation, that resolution is appended to the registry as a new row, so the *next* preflight recognizes it instead of re-deriving it.
   - (This ancestor scan is the machine check for the epic's **append-only invariant** — see Standing rules: *epic integration*. The registry keeps the check strict while retiring repeat investigations of an already-understood deviation.)

## Step 1 — Set up track branches + worktrees (once; **per-slice** under `--parallel` — see *Autonomous & parallel execution*)

```bash
ROOT=$(git rev-parse --show-toplevel)
SLUG="<slug>"
WT="$(dirname "$ROOT")/.tdd-wt/$SLUG"        # worktrees live OUTSIDE the repo
git switch "feature/$SLUG"

git branch "feature/$SLUG-code" "feature/$SLUG" 2>/dev/null || true
git branch "feature/$SLUG-test" "feature/$SLUG" 2>/dev/null || true
git worktree add "$WT/code" "feature/$SLUG-code"
git worktree add "$WT/test" "feature/$SLUG-test"

# Provision gitignored build deps in EACH worktree (from validation.md -> Provisioning).
# A freshly-added worktree has no node_modules / generated clients, so done-gates would
# fail for the WRONG reason without this. >>> Substitute the REAL provisioning commands: <<<
for W in "$WT/code" "$WT/test"; do
  ( cd "$W" \
      && ln -s "$ROOT/node_modules" node_modules \   # = validation.md Provisioning: dependencies
      && npx prisma generate )                        # = validation.md Provisioning: codegen (or omit)
done

# Glob handling: put EACH glob from validation.md into an array as its own
# QUOTED element — a git pathspec — so GIT does the matching, never the shell.
# (Unquoted $GLOBS get word-split AND filename-expanded by bash against the cwd
# before git sees them: non-deterministic, depends on shell opts + on-disk files.)
# The ':(glob)' magic gives predictable gitignore-style '**' semantics.
# >>> Substitute the REAL globs from the contract (these are placeholders): <<<
SRC_PATHSPECS=(  ':(glob)src/**'  )                          # = validation.md SRC_GLOBS
TEST_PATHSPECS=( ':(glob)tests/**'  ':(glob)**/*.test.*' )   # = validation.md TEST_GLOBS

# Blindfold each track branch by removing the opposite side's tracked files.
( cd "$WT/code" && git rm -q -r --ignore-unmatch -- "${TEST_PATHSPECS[@]}" \
    && git commit -q -m "tdd: blindfold code tree (remove tests)" || true )
( cd "$WT/test" && git rm -q -r --ignore-unmatch -- "${SRC_PATHSPECS[@]}" \
    && git commit -q -m "tdd: blindfold test tree (remove src)" || true )
```

Note: build **manifests/lockfiles** the coder may edit (e.g. `package.json`) are **coder-owned** — keep them in `SRC_GLOBS` so assembly pulls them from the code branch. The test command must already run with existing test tooling (confirmed in the contract); if the test-writer needs a *new* test dependency, that's a contract gap → escalate, don't patch silently.

Note: the orchestrator creates worktrees **only** on the disposable track branches `feature/$SLUG-code` / `feature/$SLUG-test` — never a standing worktree on the **epic/integration** branch (see Standing rules: *never strand the epic ref*). A branch held checked out can't be fast-forwarded by fetch/push, so a standing epic worktree would freeze its local ref and re-create the stale-base trap from Step 0.6. The epic advances **only** by pushing to origin (Step 4); the sole epic checkout the orchestrator ever makes is the *transient* integration merge there.

## Step 2 — Per-slice loop (dependency order)

> Default is **sequential**, one slice at a time. Under `--parallel` (default in `--autonomous`) the worktree topology and scheduling below are overlaid by **Autonomous & parallel execution** (independent slices run in waves, each in its own worktree pair); under `--autonomous` the human-escalation points in 2c are overlaid too (parked to a queue). Read that section alongside this one. Everything else here — blindness, real gates, seams, the post-green verifier, merge-only integration — is identical in every mode.

For each slice `S` (domain `D` → agents `test-writer-D`, `blind-coder-D`):

### 2a. Dispatch both tracks IN PARALLEL
Launch both subagents in a single message (or as background tasks). Give each only what it needs; never hand a worker the other side's artifacts.

**Point to the spec; never paraphrase it.** A dispatch message carries only role, paths, commands, and **pointers to the spec sections** the slice covers (e.g. `spec.md §B10`) — never a restatement of the spec's behaviors or rules. A paraphrase is a second, weaker source of truth: when it and the frozen spec diverge (you compress five behaviors to four, or drop the catch-all clause), a worker may orient to the paraphrase instead of the spec. That is the root cause of the S2-class miss — and the failure mode isn't always a harmless extra iteration; a paraphrase both workers read can make *both* tracks agree on the same wrong reading. The frozen `spec.md` must be the only place either worker reads behavior from.

- → `test-writer-D` (cwd `$WT/test`): *"Slice `S.id`: `S.description`. Authoritative spec, read it directly: `.tdd/<slug>/spec.md` §<this slice's sections> (this message points to the spec, it does not restate it). Validation contract: `.tdd/<slug>/validation.md` — use its REAL commands. Write the failing tests for THIS slice only, per your skills; make the suite run (throwaway stub is fine, keep it untracked) and watch each new test go RED for the spec'd reason. Report your done-gate result + any candidate spec-gaps."*
- → `blind-coder-D` (cwd `$WT/code`): *"Slice `S.id`: `S.description`. Authoritative spec, read it directly: `.tdd/<slug>/spec.md` §<this slice's sections> (this message points to the spec, it does not restate it). Validation contract: `.tdd/<slug>/validation.md` — use its REAL lint/typecheck/build commands. Implement THIS slice only, simplest code that satisfies the spec, per your skills. Report your done-gate result + any candidate spec-gaps."*

Each worker commits its own work to its own branch (`feature/$SLUG-code` / `feature/$SLUG-test`). Wait for both done-gates. If either reports a candidate spec-gap, hold and treat it at 2c.

### 2b. Assemble + dispatch the arbiter
```bash
cd "$ROOT" && git switch "feature/$SLUG"

# Same pathspecs as Step 1 — re-declared, since shell state doesn't persist across steps.
SRC_PATHSPECS=(  ':(glob)src/**'  )
TEST_PATHSPECS=( ':(glob)tests/**'  ':(glob)**/*.test.*' )

# MIRROR each side from its track branch — don't just overlay. Plain
# 'git checkout <branch> -- <glob>' only adds/updates matched paths and NEVER
# deletes, so a later slice that REMOVES a src/test file would leave a stale copy
# here. Dropping the globbed paths first, then checking out fresh, makes deletions
# on a track branch propagate. (Scoped to SRC/TEST pathspecs — .tdd/ + shared
# config are never touched.)
git rm -q -r --ignore-unmatch -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}"
git checkout "feature/$SLUG-code" -- "${SRC_PATHSPECS[@]}"     # real implementation
git checkout "feature/$SLUG-test" -- "${TEST_PATHSPECS[@]}"    # real tests
```
The integration tree now **mirrors** the combined state — current `src/` from the code branch + current `tests/` from the test branch, with any file a track branch *deleted* also gone here (that's what the leading `git rm` buys). The test-writer's throwaway stub is untracked, so it is never on the test branch and never pulled. Then:

- → `arbiter` (cwd `$ROOT`): *"Integration tree on `feature/$SLUG`, slice `S.id` just assembled (real src + real tests). Spec: `.tdd/<slug>/spec.md`. Slice manifest: `.tdd/<slug>/slices.md`. Validation contract: `.tdd/<slug>/validation.md` — run the full check + lint + typecheck + build. Report exactly what you observe. Scan the diff for anti-cheat. Before any green, verify every integration seam this slice declares in `slices.md` actually resolves from its named entry point (a compilable smoke-import — not mere presence in `src/`); an unresolved seam is a code-fault. For a **type** seam, also probe its narrowness — a deliberately-bad literal assigned to the exported type must fail to compile; a type that silently widened (e.g. a union collapsed to `string`) is a code-fault. On red, classify each failure against the spec and route. Author nothing."*

### 2c. Route the verdict (loop until green or breaker)
Maintain a per-slice **iteration counter** (max **3**) and a private **attempt history** per worker (hub-and-spoke: you hold it; workers never see each other's).

- **GREEN** (all checks pass, pristine, no gaming, every declared integration seam resolves from its entry point) → **then the cross-model verifier, if enabled.** Read `.tdd/codex.toml`; if `enabled` and `points` includes `post_green`, dispatch `codex-judge` on this assembled slice *before* committing:
  - → `codex-judge` (cwd `$ROOT`): *"Post-green verify slice `S.id`. Spec: `.tdd/<slug>/spec.md` §<sections>. Assembled diff: real `src/` + `tests/` for this slice. Validation output: «<the gates you just ran>». Run Codex read-only per your skills; return its structured verdict verbatim — do not judge it yourself."*
  - **Codex `pass`** (agrees with your GREEN) → commit the slice and move on:
    ```bash
    git add -A && git commit -q -m "S<n> ${S.id}: ${S.description} (green)"
    ```
  - **Codex `concerns`** (divergence — arbiter GREEN but Codex flags a spec-gap / anti-cheat / safety / missing-edge / type-quality) → **do NOT commit, do NOT auto-green.** Escalate to the human now (autonomous mode: park to the escalation queue) with *both* verdicts; you never overrule a Codex `concerns`. Then treat a confirmed finding as the matching fault and route it (a `spec-gap` kind → escalate to `/tdd:spec`; an implementation/test fault → re-dispatch the relevant worker with the arbiter's NL framing of the finding).
  - **`limit`** (the verifier returns `limit`, meaning **every** provider in its chain was rate-limited — a single provider's limit is handled by falling back to the next, e.g. Codex → Gemini, *inside* the judge) → neither a fault nor a `concerns`: do **not** commit, escalate, or fabricate a pass. Mark the slice `green-unverified` (arbiter passed, verification still owed) and **pause the run** per *Limits, checkpointing & resume* (the judge already did short retries + fallback before returning `limit`).
  - **Verifier disabled or `codex` absent** → commit as before. Interactive falls back to the Claude-only gate; this is the default and leaves prior behavior unchanged.
  - **Verifier `mode`** (from `.tdd/codex.toml`) selects how the GREEN decision combines the arbiter and the verifier — pick the branch that matches `mode`:
    - **`split`** (default, iii): the Claude arbiter is the in-loop judge; the verifier is an independent cross-check at the leak points. Green = arbiter GREEN **and** (if the verifier ran) `pass`; if the verifier is disabled/absent, arbiter GREEN alone suffices (the fallback above). Divergence escalates.
    - **`panel`** (ii): the verifier is **mandatory and co-equal** — green requires arbiter GREEN **and** verifier `pass`; a missing/limited verifier is **not** a silent fallback to arbiter-only (honor `on_missing`). Use when you want two independent green votes on every slice.
    - **`sole`** (i): the verifier **is** the judge. The arbiter still runs the real checks (gates, seams, anti-cheat) and reports what it observes, but the GREEN decision is the verifier's `pass`, not a separate Claude verdict; if the verifier can't run, honor `on_missing` — do **not** fall back to Claude-as-judge (that would defeat `sole`).
- **RED → code-fault** → re-dispatch `blind-coder-D` (cwd `$WT/code`) with the arbiter's **NL analysis only**: *"Slice `S.id`, re-dispatch. Your implementation diverges from the spec as follows: «`<arbiter analysis>`». Fix the implementation to match the spec. Do not seek the tests. Re-run your done-gate."* Then re-assemble (2b) and re-arbitrate.
- **RED → test-fault** → re-dispatch `test-writer-D` (cwd `$WT/test`) with the arbiter's **NL analysis only**: *"Slice `S.id`, re-dispatch. Your test mis-encodes the spec as follows: «`<arbiter analysis>`». Fix the test to match the spec. Do not seek the implementation. Re-run your done-gate."* Then re-assemble (2b) and re-arbitrate.
- **RED → spec-gap** (test and code each defend a reasonable-but-different reading) → **ESCALATE to the human now**: present the two competing readings plainly and stop this slice. Do not pick a winner; a spec-gap is fixed in the spec (re-run `/tdd:spec` on it), not buried in code or tests.
- **anti-cheat flagged** → treat as the relevant fault, re-dispatch with the flag made explicit; never accept a green that the arbiter marked gamed.

**Circuit breaker:** if the iteration counter hits 3, **or** the arbiter notes **oscillation** (the same fault returning unchanged), stop the slice and escalate to the human with a STUCK report: the slice, the persistent fault, and what each side tried. Do not keep looping.

## Step 3 — Final whole-feature check
After the last slice greens, run the contract's **full check + lint + typecheck + build** once more on the complete integration tree, **and re-verify that every integration seam in `slices.md` still resolves from its entry point** (a later slice can regress a re-export an earlier seam relied on) — to catch cross-slice regressions at the seams. If red, treat it as a new arbiter pass (route per 2c) for the offending slice. Only an all-green, all-seams-resolve whole feature proceeds.

## Step 4 — Push (automatic, only after full green)
The feature branch was created for exactly this, so push it without a separate prompt — **but** with guardrails:
```bash
if git remote get-url origin >/dev/null 2>&1; then
  git push -u origin "feature/$SLUG"     # NEVER --force
else
  echo "No 'origin' remote — branch feature/$SLUG is ready locally; push manually."
fi
```
- Push **only** after Step 3 is green (we never push broken code — the arbiter's verdict is the gate).
- Never force-push. If the remote rejects (non-fast-forward on a re-run), report it and stop — do not overwrite remote history.
- **Product-copy hold.** If any slice in this feature created or changed strings the spec marked as **product copy** (user-facing wording — dictionary text, labels, bot/UI messages), stop **before** advancing the epic and get an explicit human OK on the *words*. A green build proves the copy is wired correctly, not that it says the right thing; wording is a product decision, not an engineering one. (Numbers inside those strings are already constant-sourced per the money checklist — only the language needs sign-off.) Keep the feature out of the epic until approved.

**Advancing the epic** (after the feature is green, pushed, and any product copy is approved) follows the **epic-integration contract** (see Standing rules: invariant / content / transport). Fetch first, then in the common case where the feature is linearly ahead of `origin/<epic>` the merge is degenerate and needs no checkout — advance the ref by a non-force push:
```bash
git fetch origin "<epic>"
git push origin "feature/$SLUG:<epic>"   # rejected if NOT a fast-forward — never --force
```
- If that push is **rejected** (`origin/<epic>` has advanced), do a **real merge**: in a transient checkout of `origin/<epic>`, `git merge` the feature tip, **run the full validation suite on the merged tree**, then non-force push and tear the checkout down. Never rebase/squash/rebuild to dodge the merge.
- **Never push `main`.** The pipeline does not write to `main` under any circumstances — epic → `main` goes only through a PR with CI and external human review, merged as a **merge commit, not a squash** (a squash voids the "epic ⊆ main" ancestor check). The pipeline's green is *necessary, not sufficient* for shipping.

## Step 5 — Clean up
Remove the track worktrees (the branches and the assembled `feature/<slug>` remain):
```bash
git worktree remove "$WT/code" --force
git worktree remove "$WT/test" --force
```
Report to the user: the feature branch, what was pushed (or that it's local-only), per-slice outcomes, and any escalations. Include a **full commit inventory** — *every* commit on the branch since the epic base, not just the blind-TDD ones:
```bash
git log --oneline --no-merges "origin/<epic>..feature/$SLUG"
```
Flag each commit that originated **outside the blind cycle** (anything not authored by a track worker or the integration step): pre-freeze edits, manual fixups, dependency bumps. Call out **schema / migration changes specially** — an edit to an already-applied migration or to `schema.prisma` is a checksum/data risk that rode in *without* a TDD gate, and it must be visible at review, not buried under the green. A green run says the *tested* work is sound; it says nothing about a side-commit that never entered the cycle.

---

## Autonomous & parallel execution

Two independent switches change how the loop above runs. **`--parallel`** changes *worktree topology and scheduling* (Steps 1–2). **`--autonomous`** changes *who handles a stop* (Steps 2c, 4, 5). `/tdd:auto` turns both on; interactively each is opt-in. Nothing else in Steps 0–5 changes — blindness, the real gates, seam + type-narrowness checks, the post-green cross-model verifier, and merge-only integration all hold exactly as written.

### Parallel slices in waves (`--parallel`; default ON under `--autonomous`)
The sequential model reuses one worktree pair and stacks slices on it. Parallel mode gives **each slice its own isolated pair**, so independent slices build at the same time (WJW measured ~4×).

- **Per-slice worktrees & branches.** For slice `S<n>`, branch `feature/$SLUG-S<n>-code` and `feature/$SLUG-S<n>-test` from the **current integration tip** of `feature/$SLUG` (which already contains every dependency that has integrated), and add worktrees `$WT/S<n>/{code,test}`. Blindfold **and provision** each pair exactly per Step 1 — per worktree, every wave.
- **Waves by the dependency DAG.** Build the DAG from `slices.md` `depends on`. A slice is *ready* when all its dependencies have integrated. Dispatch **all ready slices concurrently** — each runs its own 2a → 2c independently, **assembling and arbitrating in its own per-slice integration context** (its own code+test tips), never the shared `feature/$SLUG` tree, which would collide across concurrent slices. A slice with an unmet edge waits; that is the only ordering constraint.
- **Integrate on green, then unblock — by assembly, NOT merge.** When a slice clears 2c (arbiter green **and** the post-green verifier, if enabled), integrate it into `feature/$SLUG` exactly as **Step 2b assembles**: `git rm` the slice's `SRC_GLOBS`+`TEST_GLOBS`, then `git checkout <slice-code-branch> -- SRC_GLOBS` and `git checkout <slice-test-branch> -- TEST_GLOBS`, and commit. **Never `git merge` the track branches** — they carry blindfold-deletion commits (the code branch `git rm`'d `tests/`, the test branch `git rm`'d `src/`), and merging them propagates those deletions: a *clean* merge with no conflict that silently wipes the other side off `feature/$SLUG` (pure data loss, verified). The committed assembly advances the integration tip and makes dependents *ready* for the next wave. Re-run the **seam check** (and the post-green verifier, if enabled) after each integration. (Merge is reserved for **epic** integration, feature → epic, where the tree is already clean — see the three-level contract.)
- **Isolation caveats.** Concurrent slices must not share a mutable external (one test DB, one fixture file): give each wave-member its own (per-slice DB name/schema), or give them a dependency edge in the manifest so they don't overlap. Per-slice worktrees multiply provisioning cost — **symlinking** deps rather than reinstalling matters here (Step 1 / domain skills).

### Autonomous handling of stops (`--autonomous`)
With no human at the console, every place Steps 2c/3 say *"escalate to the human now"* becomes: **park to a queue and keep going.**

- **Escalation queue** `.tdd/<slug>/escalations.md` — append a row for each: a **spec-gap** (test and code each defensible against the spec), a **circuit-breaker** trip (3 iterations / oscillation), and any **Claude-arbiter ↔ Codex divergence** (post-green or pre-freeze). The affected slice **halts**; other independent slices **keep running their waves**. Autonomy never invents a resolution to a genuine ambiguity — it records it and moves on.
- **Product-copy queue** `.tdd/<slug>/product-copy.md` — strings the spec marked *product copy* collect here for human wording sign-off at the epic → `main` PR; they never auto-ship.
- **No silent green.** A parked slice is not green and is not integrated; it cannot unblock dependents. The run finishes the slices it *can* and then stops — a partial, honest result beats a fabricated one.
- **Verifier required.** Autonomous mode leans on the cross-model verifier as the gate that replaces the human; honor `.tdd/codex.toml` `on_missing` (`refuse` — don't run autonomously without it; or `warn` + stamp every output `UNVERIFIED`). Either way, **nothing reaches `main` without a human** (epic → `main` is always a PR + CI + review).

### Autonomous report (overrides Step 5)
End with a machine-readable summary a human reads after an unattended or scheduled run: per-slice outcome (**integrated** / **parked + why**), the **escalation queue**, the **product-copy queue**, the **decision-log** carried from the spec, and the **full commit inventory** (Step 5 already requires this — keep flagging side-commits, especially migration edits).

---

## Limits, checkpointing & resume

A long run can exhaust **Claude's** limit (which kills the orchestrator itself) or **Codex's** (which fails the verifier call). Neither must lose progress, and neither is a *fault* — a quota error is transient, never a `concerns` and never an escalation. The run survives by checkpointing eagerly and resuming from the checkpoint on an hourly schedule.

### The checkpoint `.tdd/<slug>/run-state.json`
Written **eagerly** — after every state transition (a slice integrated, parked, a verdict received, a pause) — and committed to `feature/$SLUG`. Eager because a Claude limit kills the process: you can't write at the moment of death, so the last good state must already be on disk. It records (schema: `assets/run-state.schema.json`): the resolved epic base; per-slice `status` (`pending` / `in_progress` / `green-unverified` / `integrated` / `parked`); each slice's iteration counter + attempt history (so the circuit breaker survives a resume); the integrated set; queue paths; run `status` (`running` / `paused-on-limit` / `complete` / `stuck`); and on a pause the `service`, `reason`, and any `retry_after` hint. Per slice it also records the **code/test branch tips (SHAs)**, the **owed arbiter verdict + verified-diff ref** (for a `green-unverified` slice), and its **wave**; plus a run-level **`lock` lease**. These make a resume *exact* — continue from the recorded SHA, re-verify the same diff — rather than approximate.

### On a limit → pause the whole run
- **Verifier limit** (the `codex-judge` returns `limit` — but **only after exhausting its whole provider chain**: a primary limit first falls back to the next provider, e.g. Codex → Gemini, with no pause): when even the fallback is limited, mark the current slice `green-unverified` (arbiter passed, verification still owed — it is **not** integrated, since integration still requires the verifier), set run `status = paused-on-limit`, checkpoint, and **stop**.
- **Claude limit**: the process dies mid-step. Nothing to do in the moment — the eager checkpoint already holds the last transition; the next resume reads it.
- Either way the run **pauses entirely** — no other slices proceed — until a resume. A limit-pause lives in the checkpoint, **not** in `escalations.md` (that file is for genuine ambiguity, never infra).

### Resume (`--resume <slug>`, hourly)
A resume is a normal headless invocation that happens to find a paused checkpoint:
1. **Take the run lease (mutual exclusion).** Atomically create `refs/tdd/lock/<slug>` by compare-and-swap: `git update-ref refs/tdd/lock/<slug> <run_id> 0000000000000000000000000000000000000000` (the all-zero old-value means "create only if absent"; the command fails otherwise). If a **live** lock is held (the checkpoint's `lock.expires_at` hasn't passed) → **another resume is already running, exit now** — this is what stops two overlapping hourly fires from double-running the slug. If the lock exists but is **expired**, steal it (force-update). Renew `expires_at` as you work; **release** it (`git update-ref -d refs/tdd/lock/<slug>`) on pause or completion.
2. Re-fetch `origin/<epic>` and re-run the **provenance** check (a resume must still start from the fresh remote tip — Step 0.6), then rebuild/verify the per-slice worktrees **at their recorded `code_tip`/`test_tip`**.
3. **Fail fast if still limited:** try one cheap operation; if the limit is still in force, re-checkpoint `paused-on-limit`, **release the lease**, and exit — don't burn quota idling.
4. Otherwise continue from the checkpoint: skip `integrated` slices; for a `green-unverified` slice run **only** the owed verification against its recorded `verified_diff` (don't rebuild it); resume `in_progress` slices from their `code_tip`/`test_tip`; dispatch `pending` slices as their deps integrate. Idempotent — nothing already done is redone.
5. When the last slice integrates, set `status = complete` and release the lease.

Worst case for any interruption: re-running **one** slice's current iteration (its workers already committed to their own branches) — never the whole run.

### Driving the hourly retry (scheduler-agnostic)
The plugin provides `--resume` + the checkpoint; the **hourly trigger is external** (same headlessness as §3.5 scheduling): `cron`/CI calling `claude -p "/tdd:run --resume <slug>"` (or `/tdd:auto --resume <slug>`) each hour, or a Cowork scheduled task. Interval defaults to 60 min (`[retry]` in `.tdd/codex.toml`); if the limit error carried a `retry_after`, prefer it over blind hourly. The schedule **self-terminates**: a resume that finds `status = complete` no-ops and reports done (remove the schedule). Nothing reaches `main` regardless — epic → `main` is always a human PR.

---

## Notifications (autonomous flow)

When `[notify]` in `.tdd/codex.toml` is enabled, the orchestrator pushes **Telegram** messages at run transitions so you can watch — or be pinged by — an unattended or scheduled run. Send-only, **autonomous flow only**, and **never blocking**: a failed notification never fails the run.

- **Secrets via env, never committed.** The config only names the env vars (`token_env`, `chat_id_env`); the bot token and chat id live in those env vars. The token must never be written to `.tdd/` (committed) or into a message.
- **Mechanism** — a plain Bot API call at each transition (the same transitions that write the checkpoint):
  ```bash
  TOKEN="${!TOKEN_ENV}"; CHAT="${!CHAT_ID_ENV}"                 # indirect: read the env vars named in config
  [ -n "$TOKEN" ] && curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode text="$MSG" >/dev/null || true   # never fail the run on a notify error
  ```
- **Two modes** (`mode` in `[notify]`):
  - **`lifecycle`** (low-noise) — only the run's spine: **started** (slug + mode), **paused-on-limit** (which service + `retry_after`), **resumed**, **completed** (integrated / parked counts), and **needs-human** (any escalation — spec-gap, Claude↔verifier divergence, breaker trip, stuck).
  - **`verbose`** — all of the above **plus** every phase: spec frozen; per slice `dispatched → green → verified (which provider) → integrated`; wave N complete; product-copy queued.
- Messages carry **status only** — never secrets, never raw code/tests. Keep them short: they're signals, not logs.

---

## Standing rules (apply throughout)

- **You author nothing.** No editing src or tests. You orchestrate git + dispatch + routing only.
- **Hub-and-spoke / the blindness wall:** all coordination flows through you; workers never talk to each other; only the arbiter's natural-language analysis crosses to a worker — **never** raw test code to the coder, **never** raw implementation to the test-writer.
- **Dispatch points, never paraphrases.** Worker dispatch messages carry role, paths, commands, and spec-section pointers only — never a restatement of the spec's normative content (see Step 2a). A paraphrase is a competing, weaker source of truth that can pull a worker off the frozen spec; the spec is the single place a worker reads behavior from.
- **Real checks only:** every gate (worker done-gates and the arbiter) runs the commands in `.tdd/<slug>/validation.md` verbatim. Never substitute, weaken, or invent a check — a made-up check that "passes" is the documented cause of false-green completions.
- **Epic integration — a three-level contract.** Folding a slice/feature into an integration or epic branch is governed at three distinct levels; keep them separate (the word *fast-forward* names a kind of **push / ref-update**, not a kind of merge). This defeats the `3be6cee` incident class, where a content-copy silently dropped a fix and its regression test while every check stayed green:
  - *Invariant (the root).* `origin/<epic>`'s history is **append-only** — any commit ever pushed to the epic stays an ancestor of it forever; nothing may drop a commit back out. The machine check is the preflight ancestor scan (Step 0.6).
  - *Content.* A feature enters the epic **only via `git merge` of its real tip** (a degenerate fast-forward merge is fine; **rebase, squash, and content-rebuild are forbidden**). *(This governs **feature → epic**, where the tree is clean. **Within** a feature, parallel blindfold track branches are **assembled** per Step 2b — never merged — since a track branch's blindfold commit `git rm`'d the other side, and merging it would propagate that deletion.)* After any **non-degenerate** merge, run the **full validation suite on the merged tree before pushing** — a real merge yields a tree neither side validated alone (the "final whole-feature check" extended to integration merges).
  - *Transport.* The epic ref on `origin` moves **only by non-force push**: `fetch` before every push, and if `origin/<epic>` has advanced, **merge first (per Content) then push** — never `--force`, no exceptions.
  - *Outward consequence.* The epic → `main` PR merges as a **merge commit, never a squash** — a squash rewrites history and voids the "epic ⊆ main" ancestor check (and the append-only invariant) at the boundary.
- **Never strand the epic ref.** Treat the local `<epic>` ref as a disposable cache: never build a cycle on it (always re-fetch `origin/<epic>` — Step 0.6), and never keep the epic checked out in a **standing** worktree. A branch held checked out can't be fast-forwarded by fetch, which is exactly how a local epic ref silently falls behind origin. A *transient* checkout to perform a non-degenerate integration merge (Content level above) is fine — fetch-first, push non-force, tear it down — what's forbidden is leaving the epic standing in a worktree across the cycle.
- **Dispatch by exact name** from the manifest's domain (`test-writer-<domain>` / `blind-coder-<domain>` / `arbiter`) — never rely on model auto-selection.
- **Escalate, don't guess:** spec-gaps and breaker trips go to the human (now mode). Burying them in code or tests just hides the problem.
- **Improve the plugin, not just your memory.** When a cycle surfaces a rule at the level of *how the pipeline itself works* (e.g. "take the base from origin, not the local ref"; "never strand the epic ref") — as opposed to a fact about *this* repo or feature — saving it only to session memory isn't enough: memory is per-session and won't survive a new session or a different project. Surface it as proposed feedback to these plugin contracts (the role/command files) so the lesson becomes durable for every future run; keep it in project memory too, but don't let that be its only home.
