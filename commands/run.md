---
name: run
description: "Phase 2-5 of the Parallax pipeline. From a frozen .parallax/ spec, build each slice with a blind test-writer + blind coder in parallel, validate-and-loop through the arbiter until green, then push the feature branch. Run /parallax:spec first."
argument-hint: "[feature-slug]   [--autonomous]  [--parallel]   [--resume]"
---

# /parallax:run — build the frozen spec, blind + arbitrated, then push

You are the **orchestrator** for Phase 2-5. You author **no code and no tests** — you set up git, dispatch the blind workers and the arbiter, route their results, and manage the branch. Workers and the arbiter do all authoring/judging via their own skills.

> **Branch namespace.** Throughout this doc `feature/` is the **default** prefix for everything the pipeline creates/pushes (the feature branch, track branches, lock, epic). It is **configurable** via `.parallax/codex.toml` `[git] branch_prefix` and read into `PREFIX` at Step 1. For a Claude Code **web (cloud) routine** (which runs with the laptop off but permits pushes only to `claude/*`), set `branch_prefix = "claude/"`; then wherever you see `feature/<slug>` below, use `${PREFIX}<slug>`. The default keeps local behaviour identical.

## The blindness model (why the git dance exists)

- The **coder** works in a worktree whose branch has **no test files** — it cannot teach-to-the-test because it cannot see the tests.
- The **test-writer** works in a worktree whose branch has **no source files** — it tests the spec, not an implementation, and creates its own throwaway stub to watch tests fail.
- The **integration tree** (the real `feature/<slug>`) is assembled by pulling **real `src/` from the code branch + real `tests/` from the test branch**. Only the **arbiter** sees this whole. Only the arbiter's **natural-language** analysis ever crosses back to a worker — never raw test code to the coder, never raw implementation to the test-writer.

## Step 0 — Preflight

1. Resolve the slug: use `$ARGUMENTS` if given, else the current `feature/<slug>` branch. **If `--resume` is passed (or a `.parallax/<slug>/run-state.json` with status `paused-on-limit` exists), this is a RESUME:** load that checkpoint and continue from it per *Limits, checkpointing & resume* — skip the fresh dispatch for already-`integrated` slices. Otherwise start fresh and create the checkpoint.
2. Read `PREFIX` from `.parallax/codex.toml` `[git] branch_prefix` (default `feature/`). `git switch ${PREFIX}<slug>`. Confirm `.parallax/<slug>/spec.md`, `.parallax/<slug>/slices.md`, `.parallax/<slug>/validation.md` exist (per-feature subdirectory, not the `.parallax/` root). If not → tell the user to run `/parallax:spec` first and stop.
3. Confirm a clean working tree and that this is a local repo (`git rev-parse --show-toplevel`). Read the three artifacts. From `.parallax/<slug>/validation.md` extract: `SRC_GLOBS`, `TEST_GLOBS`, and the commands (fast, full, lint, typecheck, build) + external setup. From `.parallax/<slug>/slices.md` extract the ordered slice list with each slice's domain and dependencies.
4. Order the slices by dependency (topological). You will process them **one at a time**; within a slice the two tracks run **in parallel**.
5. **Cross-branch value scan (catch duplicated business values before they merge).** The blind tracks each build from `main` independently, so neither can see a value that already lives as a named constant on a *sibling* feature branch of the same epic — but once both branches merge, the same tariff/threshold sitting as a bare literal here and a named constant there will silently drift the moment someone edits one. You are the only party that sees across branches, so check now, before dispatching:
   - Pull the salient business values out of `.parallax/<slug>/spec.md` — money amounts, rates, thresholds, fixed quantities, and named sets/enums.
   - Grep each across `main` and the other live feature branches of the epic:
     ```bash
     PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"
     SIBLINGS=$(git branch --format='%(refname:short)' | grep "^${PREFIX}" | grep -v -- "$SLUG")
     for B in main $SIBLINGS; do
       git grep -n -F -- "<value>" "$B" 2>/dev/null && echo "   ^ found on $B"
     done
     ```
   - A hit on a sibling branch means the value already has a home. **Stop and ask the lead** how to reconcile: import the existing constant (preferred), or — if the duplication is deliberate (e.g. a display string that copies a price) — record in the spec which side is the source of truth and how the two stay in sync. Don't dispatch the slice until it's resolved; a duplicated literal is a post-merge bug no per-branch gate can catch, because both branches are green in isolation.
6. **Base provenance check (trust the base only if it really contains what it claims).** A feature usually branches not from `main` but from an integration/epic base meant to already contain earlier features of the epic. That base can silently be missing commits two ways, and a green run reveals neither (validation only checks what's in the tree): it was assembled by **copying content** instead of merging real tips, or the **local** epic ref has **lagged origin** — when a branch is checked out in another session's worktree, git won't fast-forward it on fetch/push, so your local `<epic>` can sit behind `origin/<epic>` by whole slices. Either way a fix that lived only in a dropped or un-pulled commit is gone *with its regression test*. So pin the base to the remote and verify it, before dispatching:
   - **Take the base from origin, never the local ref.** `git fetch origin <epic>` and set the cycle base = `origin/<epic>`. The local `<epic>` ref is only a cache and may be stale (see above) — never build a cycle on it directly.
   - With the lead, list the prior feature tips that base is supposed to incorporate (the live `${PREFIX}*` siblings from step 5 are your candidates). For each, assert it is an ancestor of the **remote** base:
     ```bash
     git fetch origin "<epic>"
     BASE="origin/<epic>"
     git merge-base --is-ancestor "<prior-feature-tip>" "$BASE" \
       || echo "MISSING: <prior-feature-tip> is not an ancestor of $BASE"
     ```
   - Any `MISSING` → first consult the **known-deviations registry** `.parallax/provenance-exceptions.md` (epic-level, at the `.parallax/` root — deliberately *not* per-feature; provenance spans the whole epic). Each row records a tip that is legitimately a non-ancestor and why it's safe: `<tip> | reason | compensated-by <commit> | content verified by <who/how> | date`. 
     - **Listed** (with a recorded compensation *and* verification) → report it as a **known exception (see registry)** and continue. The archaeology was already done once; don't redo it by hand every run.
     - **Not listed** → **stop and escalate to the human.** The base may be poisoned (built by copy/rebuild, or the local ref was stale); a green here would be meaningless, and the fix is to rebuild the base by *merging* the real tips into `origin/<epic>` — not to proceed. Once the human confirms it's a benign, compensated deviation, that resolution is appended to the registry as a new row, so the *next* preflight recognizes it instead of re-deriving it.
   - (This ancestor scan is the machine check for the epic's **append-only invariant** — see Standing rules: *epic integration*. The registry keeps the check strict while retiring repeat investigations of an already-understood deviation.)

## Step 1 — Set up track branches + worktrees (once; **per-slice** under `--parallel` — see *Autonomous & parallel execution*)

```bash
ROOT=$(git rev-parse --show-toplevel)
SLUG="<slug>"
# Branch namespace — default "feature/", configurable via .parallax/codex.toml [git] branch_prefix.
# Set "claude/" for Claude Code WEB (cloud) routines (laptop-off), whose push policy allows only claude/*.
PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"
WT="$(dirname "$ROOT")/.parallax-wt/$SLUG"        # worktrees live OUTSIDE the repo
git switch "${PREFIX}$SLUG"

git branch "${PREFIX}$SLUG-code" "${PREFIX}$SLUG" 2>/dev/null || true
git branch "${PREFIX}$SLUG-test" "${PREFIX}$SLUG" 2>/dev/null || true
git worktree add "$WT/code" "${PREFIX}$SLUG-code"
git worktree add "$WT/test" "${PREFIX}$SLUG-test"

# Provision gitignored build deps in EACH worktree (from validation.md -> Provisioning).
# A freshly-added worktree has no node_modules / generated clients, so done-gates would
# fail for the WRONG reason without this. >>> Substitute the REAL provisioning commands: <<<
#   - dependencies: symlink the main checkout's node_modules (fast) or install
#   - codegen: e.g. `npx prisma generate` (or omit)
for W in "$WT/code" "$WT/test"; do
  ( cd "$W" && ln -s "$ROOT/node_modules" node_modules && npx prisma generate )
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
    && git commit -q -m "parallax: blindfold code tree (remove tests)" || true )
( cd "$WT/test" && git rm -q -r --ignore-unmatch -- "${SRC_PATHSPECS[@]}" \
    && git commit -q -m "parallax: blindfold test tree (remove src)" || true )
```

Note: build **manifests/lockfiles** the coder may edit (e.g. `package.json`) are **coder-owned** — keep them in `SRC_GLOBS` so assembly pulls them from the code branch. The test command must already run with existing test tooling (confirmed in the contract); if the test-writer needs a *new* test dependency, that's a contract gap → escalate, don't patch silently.

Note: the orchestrator creates worktrees **only** on the disposable track branches `feature/$SLUG-code` / `feature/$SLUG-test` — never a standing worktree on the **epic/integration** branch (see Standing rules: *never strand the epic ref*). A branch held checked out can't be fast-forwarded by fetch/push, so a standing epic worktree would freeze its local ref and re-create the stale-base trap from Step 0.6. The epic advances **only** by pushing to origin (Step 4); the sole epic checkout the orchestrator ever makes is the *transient* integration merge there.

## Step 2 — Per-slice loop (dependency order)

> Default is **sequential**, one slice at a time. Under `--parallel` (default in `--autonomous`) the worktree topology and scheduling below are overlaid by **Autonomous & parallel execution** (independent slices run in waves, each in its own worktree pair); under `--autonomous` the human-escalation points in 2c are overlaid too (parked to a queue). Read that section alongside this one. Everything else here — blindness, real gates, seams, the post-green verifier, merge-only integration — is identical in every mode.

For each slice `S` (domain `D` → agents `test-writer-D`, `blind-coder-D`):

### 2a. Dispatch both tracks IN PARALLEL
Launch both subagents in a single message (or as background tasks). Give each only what it needs; never hand a worker the other side's artifacts.

**Point to the spec; never paraphrase it.** A dispatch message carries only role, paths, commands, and **pointers to the spec sections** the slice covers (e.g. `spec.md §B10`) — never a restatement of the spec's behaviors or rules. A paraphrase is a second, weaker source of truth: when it and the frozen spec diverge (you compress five behaviors to four, or drop the catch-all clause), a worker may orient to the paraphrase instead of the spec. That is the root cause of the S2-class miss — and the failure mode isn't always a harmless extra iteration; a paraphrase both workers read can make *both* tracks agree on the same wrong reading. The frozen `spec.md` must be the only place either worker reads behavior from.

- → `test-writer-D` (cwd `$WT/test`): *"Slice `S.id`: `S.description`. Authoritative spec, read it directly: `.parallax/<slug>/spec.md` §<this slice's sections> (this message points to the spec, it does not restate it). Validation contract: `.parallax/<slug>/validation.md` — use its REAL commands. Write the failing tests for THIS slice only, per your skills; make the suite run (throwaway stub is fine, keep it untracked) and watch each new test go RED for the spec'd reason. Report your done-gate result + any candidate spec-gaps."*
- → `blind-coder-D` (cwd `$WT/code`): *"Slice `S.id`: `S.description`. Authoritative spec, read it directly: `.parallax/<slug>/spec.md` §<this slice's sections> (this message points to the spec, it does not restate it). Validation contract: `.parallax/<slug>/validation.md` — use its REAL lint/typecheck/build commands. Implement THIS slice only, simplest code that satisfies the spec, per your skills. Report your done-gate result + any candidate spec-gaps."*

Each worker commits its own work to its own branch (`${PREFIX}$SLUG-code` / `${PREFIX}$SLUG-test`). Wait for both done-gates. If either reports a candidate spec-gap, hold and treat it at 2c.

### 2b. Assemble + dispatch the arbiter
```bash
cd "$ROOT"
PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"   # as Step 1
git switch "${PREFIX}$SLUG"

# Same pathspecs as Step 1 — re-declared, since shell state doesn't persist across steps.
SRC_PATHSPECS=(  ':(glob)src/**'  )
TEST_PATHSPECS=( ':(glob)tests/**'  ':(glob)**/*.test.*' )

# MIRROR each side from its track branch — don't just overlay. Plain
# 'git checkout <branch> -- <glob>' only adds/updates matched paths and NEVER
# deletes, so a later slice that REMOVES a src/test file would leave a stale copy
# here. Dropping the globbed paths first, then checking out fresh, makes deletions
# on a track branch propagate. (Scoped to SRC/TEST pathspecs — .parallax/ + shared
# config are never touched.)
git rm -q -r --ignore-unmatch -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}"
git checkout "${PREFIX}$SLUG-code" -- "${SRC_PATHSPECS[@]}"     # real implementation
git checkout "${PREFIX}$SLUG-test" -- "${TEST_PATHSPECS[@]}"    # real tests
```
The integration tree now **mirrors** the combined state — current `src/` from the code branch + current `tests/` from the test branch, with any file a track branch *deleted* also gone here (that's what the leading `git rm` buys). The test-writer's throwaway stub is untracked, so it is never on the test branch and never pulled. Then:

- → `arbiter` (cwd = the **assembled tree**: sequential `$ROOT` on `${PREFIX}$SLUG`; **parallel `$WT/S<n>/assembly`**, never `$ROOT` — see *Autonomous & parallel execution*): *"Assembled integration tree for slice `S.id` (real src + real tests). Spec: `.parallax/<slug>/spec.md`. Slice manifest: `.parallax/<slug>/slices.md`. Validation contract: `.parallax/<slug>/validation.md` — run the full check + lint + typecheck + build. Report exactly what you observe. Scan the diff for anti-cheat. Before any green, verify every integration seam this slice declares in `slices.md` actually resolves from its named entry point (a compilable smoke-import — not mere presence in `src/`); an unresolved seam is a code-fault. For a **type** seam, also probe its narrowness — a deliberately-bad literal assigned to the exported type must fail to compile; a type that silently widened (e.g. a union collapsed to `string`) is a code-fault. On red, classify each failure against the spec and route. Author nothing."*

### 2c. Route the verdict (loop until green or breaker)
Maintain a per-slice **iteration counter** (max **3**) and a private **attempt history** per worker (hub-and-spoke: you hold it; workers never see each other's).

**The verifier `mode` (from `.parallax/codex.toml`) decides *who judges* — apply it before the green/red routing:**
- **`split`** (default, iii): the Claude **arbiter judges** the slice (the GREEN/RED routing below); a post-green verifier independently **cross-checks** a GREEN — a divergence escalates, never auto-greens. The arbiter is authoritative for RED.
- **`panel`** (ii): same, but the verifier is **mandatory and co-equal** — a slice is green only if the arbiter GREENs **and** the verifier `pass`es; a missing/limited verifier is not a silent fallback (honor `on_missing`).
- **`sole`** (i): the arbiter **runs** the checks (gates, seams, anti-cheat) but holds **no verdict authority** — it reports observations, and you dispatch `codex-judge` with those + the assembled diff to **judge the slice itself, for GREEN _and_ RED**. Codex `pass` → commit/integrate; Codex `concerns`/fault → route by its classification (code-fault → coder, test-fault → test-writer, spec-gap → escalate). Claude never independently greens or reds in `sole`; if the verifier is unavailable, honor `on_missing` (never fall back to Claude-as-judge).

> `mode` semantics (`panel`/`sole`) are contract behaviours **executed by the orchestrating model** and validated by integration runs — the unit harness checks that the branches exist and the deterministic git/schema mechanics, not the model's judgment. The GREEN/RED routing below is written for `split`/`panel`; under `sole`, substitute the verifier as judge per above.

- **GREEN** (all checks pass, pristine, no gaming, every declared integration seam resolves from its entry point) → **then the cross-model verifier, if enabled.** Read `.parallax/codex.toml`; if `enabled` and `points` includes `post_green`, dispatch `codex-judge` on this assembled slice *before* committing:
  - → `codex-judge` (cwd = the **assembled tree**: sequential `$ROOT`; **parallel `$WT/S<n>/assembly`** — the judge must see the tree actually under review, not the shared root): *"Review slice `S.id`. Spec: `.parallax/<slug>/spec.md` §<sections>. Assembled tree: current `src/` + `tests/` for this slice. Validation output: «<the gates you just ran>». Prior findings to regression-check FIRST: «<the open+fixed findings from `.parallax/<slug>/reviews/S<n>.json`, **with their ids**>». Run the verifier read-only per your skills; emit a **review round** (`assets/codex/review-round.schema.json`): the findings you see now (echo the **id** of any prior finding you are re-reporting) + the prior ones you positively re-verified as `resolved` (cite their **id**, so a fix is matched precisely even when two defects share a file+section). Do not judge, filter, or merge it yourself."*
  - **The verifier round is dispositioned MECHANICALLY — a `pass` does NOT bypass the ledger.** Whatever the verdict (`pass` **or** `concerns`), do **not** commit by hand: fold the round into the per-slice ledger and let `triage.py` decide. A bare `pass` that merely omits a still-open prior finding must not slip through — `triage.py` re-judges the **whole** ledger, so any prior `open`/`regressed` finding the verifier did not positively list under `resolved` is still live and still blocks (verified: routing such a pass through merge+triage yields `escalate`/`block`, never green). Claude never authors the ledger or decides green by hand:
    ```bash
    SID="S<n>"; LEDGER=".parallax/$SLUG/reviews/$SID.json"           # ONE ledger PER SLICE
    ASSEMBLED="$ROOT"                                                 # sequential; PARALLEL: "$WT/$SID/assembly"
    # The tree under review is STAGED, not committed (assembly stages src+tests; the integration
    # commit happens later). Hash the INDEX with `git write-tree`, NEVER `HEAD^{tree}` — HEAD has not
    # moved, so a stale codex-verified fix would re-match a since-changed tree (v0.21 P0#1 false-green).
    # Require a clean worktree-vs-index, so the SHA is exactly what the verifier read on disk.
    git -C "$ASSEMBLED" diff --quiet || { echo "ESCALATE: unstaged changes under review — cannot certify"; exit 2; }
    DIFF=$(git -C "$ASSEMBLED" write-tree)                            # content SHA of the ACTUAL staged tree
    python3 scripts/merge-ledger.py "$LEDGER" "$ROUND_JSON" --slice "$SID" --current-diff "$DIFF" --slug "$SLUG"
    python3 scripts/triage.py "$LEDGER" --policy .parallax/codex.toml --current-diff "$DIFF"; case $? in   # 0 green / 1 block / 2 escalate
      0) git add -A && git commit -q -m "$SID ${S.id}: green (advisories, if any, recorded)";;
      1) echo "BLOCK: route each blocker to its fault side, fix, then re-review (FRESH verifier, +1 round)";;
      2) echo "ESCALATE/PARK: escalation queue (finding + Claude's ledgered rebuttal, if contesting)";;
    esac
    ```
    Why this can't be gamed: `merge-ledger.py` is the **only** writer of findings (it maps the verifier's review round into the ledger by fingerprint/id — Claude invents no `id`/`spec_ref`/`evidence`); `triage.py` reads the `[review]` policy **only** from the trusted `.parallax/codex.toml` (never the ledger) and **fails closed** (no validator ⇒ `escalate`, never green); and a `fixed` finding counts **only** if the verifier verified it (`verified_by=codex`) against the **current** `--current-diff` — now the `write-tree` of the *actual staged tree*, so a fix checked against an earlier tree no longer re-matches. Then act on the decision:
       - **`block`** → route each blocker to its fault side with the arbiter's **NL framing** (`code-fault` → coder, `test-fault` → test-writer, `spec-gap`/`safety`/`anti-cheat` → `/parallax:spec` or the human) — never raw verifier text across the blindness wall. After the fix re-greens, **re-review with a fresh verifier**; it regression-checks the ledger first, and `merge-ledger.py` records the new round (+1 `rounds_used`).
       - **`escalate`** → park with the finding. The **one** thing Claude may add to the ledger is a `claude_rebuttal` (`duplicate`/`not-reproducible`/`contradicts-spec`/`out-of-scope`) — and a rebuttal can only **escalate** a blocker to a human, **never** green it; it is never a silent drop.
       - **`green`** (no live blocker: only `low` advisories remain, or every blocker is a codex-verified fix against the current `write-tree`) → committed above (case `0`); advisories go to the run report (and verbose Telegram), not to a block.
  - **`limit`** (the verifier returns `limit`, meaning **every** provider in its chain was rate-limited — a single provider's limit is handled by falling back to the next, e.g. Codex → Gemini, *inside* the judge) → neither a fault nor a `concerns`: do **not** commit, escalate, or fabricate a pass. Mark the slice `green-unverified` (arbiter passed, verification still owed) and **pause the run** per *Limits, checkpointing & resume* (the judge already did short retries + fallback before returning `limit`).
  - **Verifier disabled or `codex` absent** → commit as before. Interactive falls back to the Claude-only gate; this is the default and leaves prior behavior unchanged.

#### Review memory, rounds & disposition
A slice can take several review rounds. Two things make that converge instead of oscillate or stall:

- **Memory is a per-slice ledger, not a session.** Each review is a **fresh** verifier (`[review] resume_codex_session = false`) — a persistent `codex exec resume` session anchors the judge on its own past findings, its non-interactive id is fragile to capture, and it wouldn't survive a cloud fresh-clone anyway. Memory lives in **one file per slice**, `.parallax/<slug>/reviews/<slice_id>.json` (so a slice can't spend another's budget), **committed to the branch** so it survives resume/cloud. A fresh verifier is handed that slice's prior findings, runs **regression pass first** (re-check `open`+`fixed` against the current diff; a reproducible `fixed` → `regressed`), then a **fresh scan**, and emits a **review round** (`assets/codex/review-round.schema.json`). This kills the `n → fix → m → variant-of-n` loop without anchoring.
- **The ledger is built mechanically — the producer never certifies itself.** `scripts/merge-ledger.py` is the **only** writer of findings: it maps the verifier's round into the ledger by **fingerprint** (`sha256(kind|spec_ref|file)` → the same defect keeps the same id across rounds), assigns ids, and sets `verified_by=codex` **only** on findings the verifier listed under `resolved`. Claude does not invent findings, `spec_ref`s, or lifecycle. A `fixed` finding therefore carries proof (`verified_by=codex` + the diff it was checked against) — and `scripts/triage.py` honors a `fixed` **only** if that proof matches the **current** `--current-diff`. A `fixed` that Claude merely stamped, or one verified against a stale tree, is treated as **live** and still blocks.
- **Disposition reads policy from trusted config, fail-closed.** `triage.py` is the single source of green/block/escalate (harness-tested) and takes its `[review]` policy **only** from `.parallax/codex.toml` — **never** from the ledger (a ledger-supplied policy could otherwise zero out `always_block_kinds` and wave a `safety` finding through; the schema also rejects a policy-bearing ledger). `low` = advisory (non-blocking); `medium`/`high` block; `safety`/`anti-cheat`/`spec-gap` and any reproducible functional error **always** block. Claude may only **contest** a blocker via a formal `claude_rebuttal`, which **escalates** to a human — it never auto-greens. The only relaxation from the old hard gate is the `low`-advisory release valve.
- **Bounded by a round budget, single-sourced.** `rounds_used` lives **only** in the per-slice ledger (run-state points at the file; it keeps no second counter that could diverge). **One `merge-ledger.py` call = one round**, and the initial post-green review is round 1 — so `[review].max_rounds` (default 2) permits at most two verifier invocations. At the cap with blockers still live, the slice **parks** (escalation queue) rather than looping on ever-smaller nits. The review budget is distinct from the worker iteration breaker (max 3).
  - **Verifier `mode`:** see *"who judges"* at the top of 2c (`split` / `panel` / `sole`) — in `panel` this GREEN is green only if the verifier also `pass`es; in `sole` the verifier, not the arbiter, made the GREEN call in the first place.
- **RED → code-fault** → re-dispatch `blind-coder-D` (cwd `$WT/code`) with the arbiter's **NL analysis only**: *"Slice `S.id`, re-dispatch. Your implementation diverges from the spec as follows: «`<arbiter analysis>`». Fix the implementation to match the spec. Do not seek the tests. Re-run your done-gate."* Then re-assemble (2b) and re-arbitrate.
- **RED → test-fault** → re-dispatch `test-writer-D` (cwd `$WT/test`) with the arbiter's **NL analysis only**: *"Slice `S.id`, re-dispatch. Your test mis-encodes the spec as follows: «`<arbiter analysis>`». Fix the test to match the spec. Do not seek the implementation. Re-run your done-gate."* Then re-assemble (2b) and re-arbitrate.
- **RED → spec-gap** (test and code each defend a reasonable-but-different reading) → **ESCALATE to the human now**: present the two competing readings plainly and stop this slice. Do not pick a winner; a spec-gap is fixed in the spec (re-run `/parallax:spec` on it), not buried in code or tests.
- **anti-cheat flagged** → treat as the relevant fault, re-dispatch with the flag made explicit; never accept a green that the arbiter marked gamed.

**Circuit breaker:** if the iteration counter hits 3, **or** the arbiter notes **oscillation** (the same fault returning unchanged), stop the slice and escalate to the human with a STUCK report: the slice, the persistent fault, and what each side tried. Do not keep looping.

## Step 3 — Final whole-feature check
After the last slice greens, run the contract's **full check + lint + typecheck + build** once more on the complete integration tree, **and re-verify that every integration seam in `slices.md` still resolves from its entry point** (a later slice can regress a re-export an earlier seam relied on) — to catch cross-slice regressions at the seams. If red, treat it as a new arbiter pass (route per 2c) for the offending slice. Only an all-green, all-seams-resolve whole feature proceeds.

## Step 4 — Push (automatic, only after full green)
The feature branch was created for exactly this, so push it without a separate prompt — **but** with guardrails:
```bash
PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"   # same as Step 1
if git remote get-url origin >/dev/null 2>&1; then
  git push -u origin "${PREFIX}$SLUG"     # NEVER --force
else
  echo "No 'origin' remote — branch ${PREFIX}$SLUG is ready locally; push manually."
fi
```
- Push **only** after Step 3 is green (we never push broken code — the arbiter's verdict is the gate).
- Never force-push. If the remote rejects (non-fast-forward on a re-run), report it and stop — do not overwrite remote history.
- **Product-copy hold.** If any slice in this feature created or changed strings the spec marked as **product copy** (user-facing wording — dictionary text, labels, bot/UI messages), stop **before** advancing the epic and get an explicit human OK on the *words*. A green build proves the copy is wired correctly, not that it says the right thing; wording is a product decision, not an engineering one. (Numbers inside those strings are already constant-sourced per the money checklist — only the language needs sign-off.) Keep the feature out of the epic until approved.

**Advancing the epic** (after the feature is green, pushed, and any product copy is approved) follows the **epic-integration contract** (see Standing rules: invariant / content / transport) — **but first a hard verification gate, because the epic is append-only.** Nothing UNVERIFIED may enter the epic: if the cross-model verifier was not a working gate for *every* integrated slice — i.e. `on_missing = "warn"` fell back so outputs are stamped `UNVERIFIED`, or any integrated slice is still `green-unverified` — then push the **feature** branch for human review but **do NOT advance the epic**; park an *epic-hold* escalation. Only a fully **VERIFIED** feature advances the epic automatically (this is the machine half of "autonomous mode leans on the verifier as the gate that replaces the human"). Then fetch first, and in the common case where the feature is linearly ahead of `origin/<epic>` the merge is degenerate and needs no checkout — advance the ref by a non-force push:
```bash
# HARD HOLD: an UNVERIFIED run never advances the append-only epic. Set PARALLAX_VERIFIED=1 ONLY
# when the verifier passed (per triage) for EVERY integrated slice; on_missing="warn" leaves it unset.
if [ "${PARALLAX_VERIFIED:-0}" != "1" ]; then
  echo "HOLD: run is UNVERIFIED — feature pushed for review; epic NOT advanced (append-only requires a verified pass). Parking an epic-hold escalation."
  exit 0
fi
git fetch origin "<epic>"
git push origin "${PREFIX}$SLUG:<epic>"   # rejected if NOT a fast-forward — never --force  (PREFIX as in Step 1; epic should share the namespace)
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
PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"
git log --oneline --no-merges "origin/<epic>..${PREFIX}$SLUG"
```
Flag each commit that originated **outside the blind cycle** (anything not authored by a track worker or the integration step): pre-freeze edits, manual fixups, dependency bumps. Call out **schema / migration changes specially** — an edit to an already-applied migration or to `schema.prisma` is a checksum/data risk that rode in *without* a TDD gate, and it must be visible at review, not buried under the green. A green run says the *tested* work is sound; it says nothing about a side-commit that never entered the cycle.

---

## Autonomous & parallel execution

Two independent switches change how the loop above runs. **`--parallel`** changes *worktree topology and scheduling* (Steps 1–2). **`--autonomous`** changes *who handles a stop* (Steps 2c, 4, 5). `/parallax:auto` turns both on; interactively each is opt-in. Nothing else in Steps 0–5 changes — blindness, the real gates, seam + type-narrowness checks, the post-green cross-model verifier, and merge-only integration all hold exactly as written.

### Parallel slices in waves (`--parallel`; default ON under `--autonomous`)
The sequential model reuses one worktree pair and stacks slices on it. Parallel mode gives **each slice its own isolated pair**, so independent slices build at the same time (WJW measured ~4×).

- **Per-slice worktrees & branches.** For slice `S<n>`, branch `${PREFIX}$SLUG-S<n>-code` and `${PREFIX}$SLUG-S<n>-test` from the **current integration tip** of `${PREFIX}$SLUG` (which already contains every dependency that has integrated) — **record that tip as the slice's `wave_base`**, since the integration diff is taken against it. Add worktrees `$WT/S<n>/{code,test,assembly}`: the **assembly** worktree is a throwaway integration context (`git worktree add --detach "$WT/S<n>/assembly" <tip>`) where this slice's diff is applied and the arbiter runs in **isolation**, so concurrent slices never collide on the shared `${PREFIX}$SLUG` tree (without it, two arbiters get either no assembled tree or a clobbered one). Blindfold the code+test pair and **provision** all three per Step 1 — every worktree, every wave.
- **`${PREFIX}$SLUG` is never checked out in parallel.** No persistent worktree holds the feature branch during a wave — `$ROOT` sits **detached** at the integration tip (`git -C "$ROOT" switch --detach "${PREFIX}$SLUG"` once, up front). The branch is a **ref advanced only by the CAS `update-ref`** from an assembly worktree; if `$ROOT` (or any worktree) had it checked out, moving the ref would leave that tree **stale and dirty** — its files wouldn't match the new tip (verified: a `D src/…` phantom deletion). All per-slice work — assembly, the **arbiter**, and the **post-green verifier** — runs in `$WT/S<n>/assembly` (the tree actually under review), never `$ROOT`.
- **Waves by the dependency DAG.** Build the DAG from `slices.md` `depends on`. A slice is *ready* when all its dependencies have integrated. Dispatch **all ready slices concurrently** — each runs its own 2a → 2c independently, **assembling and arbitrating in its own per-slice integration context** (its own code+test tips in `$WT/S<n>/assembly`), never the shared `${PREFIX}$SLUG` tree, which would collide across concurrent slices. A slice with an unmet edge waits; that is the only ordering constraint.
- **Integrate on green — transactionally, in the slice's assembly worktree.** When a slice clears 2c (arbiter green **and** the post-green verifier, if enabled), apply ONLY its delta (vs the recorded `wave_base` `WB`) **in its own `$WT/S<n>/assembly` worktree**, never the shared `${PREFIX}$SLUG` tree; advance `${PREFIX}$SLUG` only after BOTH patches apply cleanly:
  ```bash
  AWT="$WT/S<n>/assembly"
  TIP=$(git -C "$ROOT" rev-parse "${PREFIX}$SLUG")            # current integration tip
  ( cd "$AWT" && git switch -q --detach "$TIP"
    { git diff --binary "$WB" "${PREFIX}$SLUG-S<n>-code" -- "${SRC_PATHSPECS[@]}"  | git apply --3way --index --binary && \
      git diff --binary "$WB" "${PREFIX}$SLUG-S<n>-test" -- "${TEST_PATHSPECS[@]}" | git apply --3way --index --binary; } || {
        git reset -q --hard; echo "CONFLICT: slice S<n> is not independent"; exit 9; }   # transactional: all-or-nothing
    git commit -q -m "S<n> assembled" )
  # serialize the move of the shared ref (CAS old-value $TIP); on a lost race, re-detach at the new tip and re-apply (the diff is vs WB):
  git -C "$ROOT" update-ref "refs/heads/${PREFIX}$SLUG" "$(git -C "$AWT" rev-parse HEAD)" "$TIP"
  ```
  Three guarantees: **`--binary`** so binary files apply (a plain text diff of a binary fails — `cannot apply binary patch without full index line`); the **assembly worktree** keeps a partial apply (a second-patch conflict) **off** `${PREFIX}$SLUG` — feature is touched only by the final CAS `update-ref`, never left half-patched (`A src/new` + `UU tests/a`); and the **CAS old-value `$TIP`** serializes concurrent integrations (a slice that loses the race re-detaches at the new tip and re-applies its `wave_base` diff). Applying only the delta **preserves slices already integrated this wave**; a `--3way` conflict = two slices touched the same lines → not independent (park / add a dependency edge, never force). Do **not** mirror `src/**`+`tests/**` from one branch (wipes other slices) and **never `git merge`** the blindfold branches. Re-run the seam check + post-green verifier after the ref-update. (Sequential Step 2b mirror is correct; merge stays for **epic** integration.)
- **Isolation caveats.** Concurrent slices must not share a mutable external (one test DB, one fixture file): give each wave-member its own (per-slice DB name/schema), or give them a dependency edge in the manifest so they don't overlap. Per-slice worktrees multiply provisioning cost — **symlinking** deps rather than reinstalling matters here (Step 1 / domain skills).

### Autonomous handling of stops (`--autonomous`)
With no human at the console, every place Steps 2c/3 say *"escalate to the human now"* becomes: **park to a queue and keep going.**

- **Escalation queue** `.parallax/<slug>/escalations.md` — append a row for each: a **spec-gap** (test and code each defensible against the spec), a **circuit-breaker** trip (3 iterations / oscillation), and any **Claude-arbiter ↔ Codex divergence** (post-green or pre-freeze). The affected slice **halts**; other independent slices **keep running their waves**. Autonomy never invents a resolution to a genuine ambiguity — it records it and moves on.
- **Product-copy queue** `.parallax/<slug>/product-copy.md` — strings the spec marked *product copy* collect here for human wording sign-off at the epic → `main` PR; they never auto-ship.
- **No silent green.** A parked slice is not green and is not integrated; it cannot unblock dependents. The run finishes the slices it *can* and then stops — a partial, honest result beats a fabricated one.
- **Verifier required.** Autonomous mode leans on the cross-model verifier as the gate that replaces the human; honor `.parallax/codex.toml` `on_missing` (`refuse` — don't run autonomously without it; or `warn` + stamp every output `UNVERIFIED`). **`warn` is a feature-only license:** an UNVERIFIED run may push the *feature* branch for human review, but it **must not advance the append-only *epic*** — Step 4's verification gate (`PARALLAX_VERIFIED`) holds it and parks an epic-hold. Only a real verified pass advances the epic automatically; `warn` never does. Either way, **nothing reaches `main` without a human** (epic → `main` is always a PR + CI + review).

### Autonomous report (overrides Step 5)
End with a machine-readable summary a human reads after an unattended or scheduled run: per-slice outcome (**integrated** / **parked + why**), the **escalation queue**, the **product-copy queue**, the **decision-log** carried from the spec, and the **full commit inventory** (Step 5 already requires this — keep flagging side-commits, especially migration edits).

---

## Limits, checkpointing & resume

A long run can exhaust **Claude's** limit (which kills the orchestrator itself) or **Codex's** (which fails the verifier call). Neither must lose progress, and neither is a *fault* — a quota error is transient, never a `concerns` and never an escalation. The run survives by checkpointing eagerly and resuming from the checkpoint on an hourly schedule.

### The checkpoint `.parallax/<slug>/run-state.json`
Written **eagerly** — after every state transition (a slice integrated, parked, a verdict received, a pause) — and committed to `feature/$SLUG`. Eager because a Claude limit kills the process: you can't write at the moment of death, so the last good state must already be on disk. It records (schema: `assets/run-state.schema.json`): the resolved epic base; per-slice `status` (`pending` / `in_progress` / `green-unverified` / `integrated` / `parked`); each slice's iteration counter + attempt history (so the circuit breaker survives a resume); the integrated set; queue paths; run `status` (`running` / `paused-on-limit` / `complete` / `stuck`); and on a pause the `service`, `reason`, and any `retry_after` hint. Per slice it also records the **code/test branch tips (SHAs)**, the **`wave_base`** (the integration tip the slice's tracks forked from — the diff base for parallel integration; required once a slice is `in_progress` or `green-unverified`), the **owed arbiter verdict + verified-diff ref** (for a `green-unverified` slice), and its **wave**; plus a run-level **`lock` lease** (whose object is the unique lock commit, required while `status` is `running`). These make a resume *exact* — continue from the recorded SHA, re-apply the same `wave_base` diff, re-verify the same diff — rather than approximate. It also records each slice's **`review_ledger`** path (`.parallax/<slug>/reviews/<id>.json`); the **`rounds_used` inside that per-slice ledger is the single source of truth** for the review budget (run-state keeps no second counter that could diverge), so a resumed run reloads the findings history and the rounds spent instead of re-discovering them.

### On a limit → pause the whole run
- **Verifier limit** (the `codex-judge` returns `limit` — but **only after exhausting its whole provider chain**: a primary limit first falls back to the next provider, e.g. Codex → Gemini, with no pause): when even the fallback is limited, mark the current slice `green-unverified` (arbiter passed, verification still owed — it is **not** integrated, since integration still requires the verifier), set run `status = paused-on-limit`, checkpoint, and **stop**.
- **Claude limit**: the process dies mid-step. Nothing to do in the moment — the eager checkpoint already holds the last transition; the next resume reads it.
- Either way the run **pauses entirely** — no other slices proceed — until a resume. A limit-pause lives in the checkpoint, **not** in `escalations.md` (that file is for genuine ambiguity, never infra).

### Resume (`--resume <slug>`, hourly)
A resume is a normal headless invocation that happens to find a paused checkpoint:
1. **Take the run lease (mutual exclusion).** The lock is a branch ref pointing at a **unique lock commit** that carries this run's `run_id` — crucial, because two fresh cloud clones share the same `HEAD`, so a lock pointing at `HEAD` is identical in both and *both* "creates" succeed as no-op same-value pushes (the v0.17 bug). A per-run-unique object makes the loser's create a real conflict.
   ```bash
   LOCKREF="refs/heads/${PREFIX}lock/$SLUG"
   LOCKOID=$(git commit-tree "$(git rev-parse HEAD^{tree})" -m "parallax-lock run_id=$RUN_ID expires=$EXPIRES")  # unique per run_id+time
   git update-ref "$LOCKREF" "$LOCKOID" 0000000000000000000000000000000000000000 || exit 0   # LOCAL: create only if absent
   git push origin --force-with-lease="$LOCKREF": "$LOCKREF"                                  # CLOUD: atomic create — pushes only if origin LACKS the ref
   ```
   `--force-with-lease="$LOCKREF":` (empty expected value) means "push only if `origin` does **not** have `$LOCKREF`": the first clone creates it; every later clone's create is **rejected** (verified with two same-`HEAD` clones → exactly one winner). `--force-with-lease="$LOCKREF":` (empty expected value) means "push only if `origin` does **not** have `$LOCKREF`". `run_id`/`expires_at` also live in `run-state.lock`. If a **live** lock is held (its `expires_at` hasn't passed) → **another run is active, exit now**. If **expired**, **steal it under a lease pinned to the oid you observed** — a bare `--force` lets two stealers both win (verified):
   ```bash
   OLD=$(git ls-remote origin "$LOCKREF" | awk '{print $1}')                       # the expired lock you observed
   NEW=$(git commit-tree "$(git rev-parse HEAD^{tree})" -m "parallax-lock run_id=$RUN_ID expires=$EXPIRES")
   git update-ref "$LOCKREF" "$NEW"
   git push origin --force-with-lease="$LOCKREF:$OLD" "$LOCKREF"                    # ONLY one stealer wins; the other's lease fails
   ```
   Renew `expires_at` as you work. **Release with a fence**, so you never clobber a successor that legitimately stole an expired lease — delete only if origin still holds *your* oid: `git push origin --force-with-lease="$LOCKREF:$LOCKOID" ":$LOCKREF"` (locally `git update-ref -d "$LOCKREF" "$LOCKOID"`, which deletes only if it still equals your oid).
2. Re-fetch `origin/<epic>` and re-run the **provenance** check (a resume must still start from the fresh remote tip — Step 0.6), then rebuild/verify the per-slice worktrees **at their recorded `code_tip`/`test_tip`**.
3. **Fail fast if still limited:** try one cheap operation; if the limit is still in force, re-checkpoint `paused-on-limit`, **release the lease**, and exit — don't burn quota idling.
4. Otherwise continue from the checkpoint: skip `integrated` slices; for a `green-unverified` slice run **only** the owed verification against its recorded `verified_diff` (don't rebuild it); resume `in_progress` slices from their `code_tip`/`test_tip`; dispatch `pending` slices as their deps integrate. Idempotent — nothing already done is redone.
5. When the last slice integrates, set `status = complete` and release the lease.

Worst case for any interruption: re-running **one** slice's current iteration (its workers already committed to their own branches) — never the whole run.

### Driving the hourly retry (scheduler-agnostic)
The plugin provides `--resume` + the checkpoint; the **hourly trigger is external** (same headlessness as §3.5 scheduling): `cron`/CI calling `claude -p "/parallax:run --resume <slug>"` (or `/parallax:auto --resume <slug>`) each hour, or a Cowork scheduled task. Interval defaults to 60 min (`[retry]` in `.parallax/codex.toml`); if the limit error carried a `retry_after`, prefer it over blind hourly. The schedule **self-terminates**: a resume that finds `status = complete` no-ops and reports done (remove the schedule). Nothing reaches `main` regardless — epic → `main` is always a human PR.

---

## Notifications (autonomous flow)

When `[notify]` in `.parallax/codex.toml` is enabled, the orchestrator pushes **Telegram** messages at run transitions so you can watch — or be pinged by — an unattended or scheduled run. Send-only, **autonomous flow only**, and **never blocking**: a failed notification never fails the run.

- **Secrets via env, never committed.** The config only names the env vars (`token_env`, `chat_id_env`); the bot token and chat id live in those env vars. The token must never be written to `.parallax/` (committed) or into a message.
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
- **Real checks only:** every gate (worker done-gates and the arbiter) runs the commands in `.parallax/<slug>/validation.md` verbatim. Never substitute, weaken, or invent a check — a made-up check that "passes" is the documented cause of false-green completions.
- **Epic integration — a three-level contract.** Folding a slice/feature into an integration or epic branch is governed at three distinct levels; keep them separate (the word *fast-forward* names a kind of **push / ref-update**, not a kind of merge). This defeats the `3be6cee` incident class, where a content-copy silently dropped a fix and its regression test while every check stayed green:
  - *Invariant (the root).* `origin/<epic>`'s history is **append-only** — any commit ever pushed to the epic stays an ancestor of it forever; nothing may drop a commit back out. The machine check is the preflight ancestor scan (Step 0.6).
  - *Content.* A feature enters the epic **only via `git merge` of its real tip** (a degenerate fast-forward merge is fine; **rebase, squash, and content-rebuild are forbidden**). *(This governs **feature → epic**, where the tree is clean. **Within** a feature, parallel blindfold track branches are **assembled** per Step 2b — never merged — since a track branch's blindfold commit `git rm`'d the other side, and merging it would propagate that deletion.)* After any **non-degenerate** merge, run the **full validation suite on the merged tree before pushing** — a real merge yields a tree neither side validated alone (the "final whole-feature check" extended to integration merges).
  - *Transport.* The epic ref on `origin` moves **only by non-force push**: `fetch` before every push, and if `origin/<epic>` has advanced, **merge first (per Content) then push** — never `--force`, no exceptions.
  - *Outward consequence.* The epic → `main` PR merges as a **merge commit, never a squash** — a squash rewrites history and voids the "epic ⊆ main" ancestor check (and the append-only invariant) at the boundary.
- **Never strand the epic ref.** Treat the local `<epic>` ref as a disposable cache: never build a cycle on it (always re-fetch `origin/<epic>` — Step 0.6), and never keep the epic checked out in a **standing** worktree. A branch held checked out can't be fast-forwarded by fetch, which is exactly how a local epic ref silently falls behind origin. A *transient* checkout to perform a non-degenerate integration merge (Content level above) is fine — fetch-first, push non-force, tear it down — what's forbidden is leaving the epic standing in a worktree across the cycle.
- **Dispatch by exact name** from the manifest's domain (`test-writer-<domain>` / `blind-coder-<domain>` / `arbiter`) — never rely on model auto-selection.
- **Escalate, don't guess:** spec-gaps and breaker trips go to the human (now mode). Burying them in code or tests just hides the problem.
- **Improve the plugin, not just your memory.** When a cycle surfaces a rule at the level of *how the pipeline itself works* (e.g. "take the base from origin, not the local ref"; "never strand the epic ref") — as opposed to a fact about *this* repo or feature — saving it only to session memory isn't enough: memory is per-session and won't survive a new session or a different project. Surface it as proposed feedback to these plugin contracts (the role/command files) so the lesson becomes durable for every future run; keep it in project memory too, but don't let that be its only home.
