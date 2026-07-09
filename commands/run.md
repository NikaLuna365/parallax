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

7. **Evidence bootstrap (v0.37.3 F5 — do this before dispatching anything).** Set the run's evidence identity once and flip the status off `frozen-spec` the moment the build starts (the exact live-run defect: `run.status` sat at `frozen-spec` through entire builds). Re-declare `EVD`/`RUN_ID` in each later step's bash block (shell state doesn't persist across steps, same as `PREFIX`):
   ```bash
   EVD=".parallax/$SLUG/evidence"
   RUN_ID="$(python3 -c 'import json;print(json.load(open(".parallax/'"$SLUG"'/evidence/run-evidence.json"))["run"]["run_id"])')"
   python3 scripts/evidence-event.py update-run "$EVD" --status running --run-id "$RUN_ID" --slug "$SLUG"
   ```
   **Canonical event append — reuse this exact one-liner shape at every wiring point below (Steps 2a/2b/2c/4 and the limits/resume sections); it validates before writing and fails closed, never a silent skip:**
   ```bash
   python3 scripts/evidence-event.py append "$EVD" --run-id "$RUN_ID" --slug "$SLUG" \
     --event-type slice_dispatched --actor main --summary "S<n>: <what happened>" --artifact-paths '{}'
   ```

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
# v0.37.3 F1 — slice-scoped monorepo mode. In a pnpm/monorepo checkout the strict whole-tree
# sweep false-positives: the test worktree legitimately keeps sibling-package source/dist for
# cross-package import resolution, and to static heuristics that looks identical to a leak.
# If validation.md's Path scoping declares "Monorepo dependency roots" for this slice, write a
# per-slice scope manifest (assets/blindfold-scope.schema.json) and pass --scope-manifest —
# NEVER a whole-tree --allow-glob '**' (the schema rejects all-wildcard globs by construction).
# protected_* = THIS slice's own new/changed paths, re-derived fresh per wave from each track's
# committed diff vs the slice's fork point, so the fail-closed core follows the actual work:
SID="S<n>"                                   # current slice id (re-declare per slice, every wave)
BASE_OID=$(git -C "$ROOT" rev-parse "${PREFIX}$SLUG")   # the tip the track branches forked from (parallel: the slice's recorded wave_base)
DEP_ALLOW_GLOBS=()   # >>> the REAL "Monorepo dependency roots" globs from validation.md, e.g. ( "packages/shared/src/**" "packages/shared/dist/**" ); leave empty for strict mode <<<
SCOPE_ARGS=()
if [ "${#DEP_ALLOW_GLOBS[@]}" -gt 0 ]; then
  SCOPE_MANIFEST=".parallax/$SLUG/blindfold-scope.$SID.json"
  IMPL_CHANGED=$(git -C "$WT/code" diff --name-only --diff-filter=ACMR "$BASE_OID" HEAD -- "${SRC_PATHSPECS[@]}")
  TEST_CHANGED=$(git -C "$WT/test" diff --name-only --diff-filter=ACMR "$BASE_OID" HEAD -- "${TEST_PATHSPECS[@]}")
  IMPL_CHANGED="$IMPL_CHANGED" TEST_CHANGED="$TEST_CHANGED" DEPS="$(printf '%s\n' "${DEP_ALLOW_GLOBS[@]}")" \
  python3 - "$ROOT/$SCOPE_MANIFEST" "$SLUG" "$SID" <<'PY'
import json, os, sys
out, slug, sid = sys.argv[1], sys.argv[2], sys.argv[3]
sp = lambda v: sorted({l.strip() for l in os.environ.get(v, "").splitlines() if l.strip()})
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump({"schema_version": "parallax-blindfold-scope-v1", "slug": slug, "slice_id": sid,
           "protected_impl_paths": sp("IMPL_CHANGED"), "protected_test_paths": sp("TEST_CHANGED"),
           "dependency_allow_globs": [l.strip() for l in os.environ["DEPS"].splitlines() if l.strip()]},
          open(out, "w"), indent=2)
PY
  SCOPE_ARGS=( --scope-manifest "$ROOT/$SCOPE_MANIFEST" )
fi
# v0.37 P0.1 — mechanically ASSERT the wall held (per wave, not just here): the code worktree must carry
# no tracked test paths, and the test worktree no tracked implementation source OR compiled build output
# (a committed dist/, an answer-bearing fixture, a leaked source file in a brownfield/monorepo checkout).
# A leak PARKS the slice fail-closed — it is contamination, never something to "continue anyway" past.
python3 "$ROOT/scripts/blindfold-guard.py" --worktree "$WT/code" --side code --slug "$SLUG" "${SCOPE_ARGS[@]}" \
  || { echo "PARK: code worktree contaminated by test paths — fail closed (v0.37 P0.1)"; exit 2; }
python3 "$ROOT/scripts/blindfold-guard.py" --worktree "$WT/test" --side test --slug "$SLUG" "${SCOPE_ARGS[@]}" \
  || { echo "PARK: test worktree contaminated by implementation/compiled output — fail closed (v0.37 P0.1 / v0.37.3 F1)"; exit 2; }
```

Re-run both `blindfold-guard.py` assertions **again before accepting each track's done-gate** (Step 2b), not only at setup — a track can fetch or generate the opposite side's files mid-slice, and the wall must hold on every wave. On every re-check **re-derive the scope manifest first** (`protected_impl_paths` / `protected_test_paths` are each track's committed diff vs the slice's fork point, so they must reflect the track's latest commit) and pass the same `--scope-manifest`; the `dependency_allow_globs` come verbatim from the frozen contract's *Monorepo dependency roots* line and never widen mid-slice. In a plain (non-monorepo) repo `DEP_ALLOW_GLOBS` stays empty and the guard runs the strict whole-tree mode exactly as v0.37. The manifest path exists **only** to retire the documented live-run workaround — a whole-tree `--allow-glob '**'` is never an acceptable monorepo answer, and the scope-manifest schema rejects it mechanically.

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

**Evidence (v0.37.3 F5 — inline, right here, not at the end of the run).** Immediately after launching both subagents, append `slice_dispatched` (actor `main`) via the canonical Step 0.7 call. As each done-gate reports back, append `test_writer_red` (actor `test-writer`) and `blind_coder_done` (actor `blind-coder`), carrying `--branch`/`--commit`/`--worktree` when known. These three calls per slice are what keep `events.jsonl` moving instead of stopping dead after `spec_frozen`.

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
The integration tree now **mirrors** the combined state — current `src/` from the code branch + current `tests/` from the test branch, with any file a track branch *deleted* also gone here (that's what the leading `git rm` buys). The test-writer's throwaway stub is untracked, so it is never on the test branch and never pulled.

**Evidence (v0.37.3 F5).** Append `arbiter_iteration_started` (actor `main`, summary naming the slice + iteration number) via the canonical Step 0.7 call immediately before dispatching the arbiter below; when it reports, append `arbiter_iteration_finished`, then the verdict event `arbiter_green` / `arbiter_red` (actor `arbiter`, the exact commands it ran in the summary, log paths in `--artifact-paths`). Every iteration gets its pair — not only the first, not only the verdict. **Checkpoint write-back (v0.38 6.1 / F7):** after EVERY arbiter round also re-persist `run-state.json` with the tracks' current `code_tip`/`test_tip` (`git rev-parse` the track branches — never a remembered value) and commit it with the events; the RUN2 drift happened exactly because RED rounds advanced a branch 3 commits past the recorded tip with no write-back, and the next session inherited the stale pointer. Then:

- → `arbiter` (cwd = the **assembled tree**: sequential `$ROOT` on `${PREFIX}$SLUG`; **parallel `$WT/S<n>/assembly`**, never `$ROOT` — see *Autonomous & parallel execution*): *"Assembled integration tree for slice `S.id` (real src + real tests). Spec: `.parallax/<slug>/spec.md`. Slice manifest: `.parallax/<slug>/slices.md`. Validation contract: `.parallax/<slug>/validation.md` — run the full check + lint + typecheck + build. Report exactly what you observe. Scan the diff for anti-cheat. Before any green, verify every integration seam this slice declares in `slices.md` actually resolves from its named entry point (a compilable smoke-import — not mere presence in `src/`); an unresolved seam is a code-fault. For a **type** seam, also probe its narrowness — a deliberately-bad literal assigned to the exported type must fail to compile; a type that silently widened (e.g. a union collapsed to `string`) is a code-fault. For a frontend seam the manifest marks **user-reachable**, router/import membership is NOT proof (v0.37.3 F2): require an actual interaction test — drive the real entry affordance (click/tab/navigate) and assert the destination content appears; a hidden/disabled entry point is a code-fault, a stale route-membership test standing in for interaction proof is a test-fault, and if the repo has no render/interaction harness, record that limitation explicitly instead of greening past it. On red, classify each failure against the spec and route. Author nothing."*

### 2c. Route the verdict (loop until green or breaker)
Maintain a per-slice **iteration counter** (max **3**) and a private **attempt history** per worker (hub-and-spoke: you hold it; workers never see each other's).

**The verifier `mode` (from `.parallax/codex.toml`) decides *who judges* — apply it before the green/red routing:**
- **`split`** (default, iii): the Claude **arbiter judges** the slice (the GREEN/RED routing below); a post-green verifier independently **cross-checks** a GREEN — a divergence escalates, never auto-greens. The arbiter is authoritative for RED.
- **`panel`** (ii): same, but the verifier is **mandatory and co-equal** — a slice is green only if the arbiter GREENs **and** the verifier `pass`es; a missing/limited verifier is not a silent fallback (honor `on_missing`).
- **`sole`** (i): the arbiter **runs** the checks (gates, seams, anti-cheat) but holds **no verdict authority** — it reports observations, and you dispatch `codex-judge` with those + the assembled diff to **judge the slice itself, for GREEN _and_ RED**. Codex `pass` → commit/integrate; Codex `concerns`/fault → route by its classification (code-fault → coder, test-fault → test-writer, spec-gap → escalate). Claude never independently greens or reds in `sole`; if the verifier is unavailable, honor `on_missing` (never fall back to Claude-as-judge).

> `mode` semantics (`panel`/`sole`) are contract behaviours **executed by the orchestrating model** and validated by integration runs — the unit harness checks that the branches exist and the deterministic git/schema mechanics, not the model's judgment. The GREEN/RED routing below is written for `split`/`panel`; under `sole`, substitute the verifier as judge per above.

- **GREEN** (all checks pass, pristine, no gaming, every declared integration seam resolves from its entry point) → **then the cross-model verifier, if enabled.** Read `.parallax/codex.toml`; if `enabled` and `points` includes `post_green`, dispatch `codex-judge` on this assembled slice *before* committing. **Evidence (v0.37.3 F5):** append `codex_round_started` (actor `main`) via the canonical Step 0.7 call right before dispatching, and `codex_round_finished` + the verdict event `verifier_pass` / `verifier_concerns` (actor `verifier`; provider + `human-authorized`/`self-continued` authorization in the summary, the ledger path in `--artifact-paths`) as soon as it returns — **before** the mechanical disposition below, so the round is on record even if `triage.py` then blocks or escalates. When the disposition lands green (case `0`, and in parallel mode after the CAS integration), append `slice_green` (actor `main`). **First assert the frozen contract in the assembly worktree is identical to HEAD** (`git -C "$ASSEMBLED" diff --quiet HEAD -- .parallax/$SLUG/{spec.md,slices.md,validation.md,slices.lock}` + no untracked) — so the verifier reads the *committed* frozen spec, not a since-edited uncommitted one; if it differs, escalate (this is the same guard repeated in the disposition block below, so the stamped `contract_hash` represents exactly what was reviewed — v0.27 P0):
  - → `codex-judge` (cwd = the **assembled tree**: sequential `$ROOT`; **parallel `$WT/S<n>/assembly`** — the judge must see the tree actually under review, not the shared root): *"Review slice `S.id`. Spec: `.parallax/<slug>/spec.md` §<sections>. Assembled tree: current `src/` + `tests/` for this slice. Validation output: «<the gates you just ran>». Prior findings to regression-check FIRST: «<the open+fixed findings from `.parallax/<slug>/reviews/S<n>.json`, **with their ids**>». Run the verifier read-only per your skills; emit a **review round** (`assets/codex/review-round.schema.json`): the findings you see now (echo the **id** of any prior finding you are re-reporting) + the prior ones you positively re-verified as `resolved` (cite their **id**, so a fix is matched precisely even when two defects share a file+section). Do not judge, filter, or merge it yourself."*
  - **The verifier round is dispositioned MECHANICALLY — a `pass` does NOT bypass the ledger.** Whatever the verdict (`pass` **or** `concerns`), do **not** commit by hand: fold the round into the per-slice ledger and let `triage.py` decide. A bare `pass` that merely omits a still-open prior finding must not slip through — `triage.py` re-judges the **whole** ledger, so any prior `open`/`regressed` finding the verifier did not positively list under `resolved` is still live and still blocks (verified: routing such a pass through merge+triage yields `escalate`/`block`, never green). Claude never authors the ledger or decides green by hand:
    ```bash
    SID="S<n>"
    ASSEMBLED="$ROOT"                                                 # sequential; PARALLEL: "$WT/$SID/assembly"
    REL_LEDGER=".parallax/$SLUG/reviews/$SID.json"                    # ONE ledger PER SLICE
    LEDGER="$ASSEMBLED/$REL_LEDGER"                                   # bind paths to the worktree under review,
    POLICY="$ASSEMBLED/.parallax/codex.toml"                          # not the shell cwd (parallel: $ASSEMBLED != $ROOT)
    SRC_PATHSPECS=(  ':(glob)src/**'  )                              # = Step 1 (re-declared; shell state doesn't persist)
    TEST_PATHSPECS=( ':(glob)tests/**'  ':(glob)**/*.test.*' )
    # Guard ONLY the reviewed scope (src+tests), NEVER .parallax/: the review ledger is metadata that
    # legitimately changes every round, and gating on it would wedge the next re-review (v0.22 P1#5).
    # Reject BOTH unstaged tracked changes AND untracked files in that scope, so the hash below equals
    # exactly what the verifier read on disk and nothing un-reviewed can ride in at commit (v0.22 P0#1).
    if ! git -C "$ASSEMBLED" diff --quiet -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}" \
       || [ -n "$(git -C "$ASSEMBLED" ls-files --others --exclude-standard -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}")" ]; then
      echo "ESCALATE: unstaged or untracked files in the reviewed scope — cannot certify"; exit 2; fi
    # DIFF = content hash of EXACTLY the reviewed code+tests in the index (mode+blob+path per file) —
    # the tree Codex reviewed. Stable against .parallax/ churn, and never HEAD^{tree} (v0.21/v0.22 P0#1).
    DIFF=$(git -C "$ASSEMBLED" ls-files -s -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}" | git hash-object --stdin)
    # The frozen contract Codex actually reads is the WORKTREE copy, but contract-hash hashes HEAD. Guard that
    # the worktree contract is IDENTICAL to HEAD (no staged/unstaged/untracked drift), so the stamped hash truly
    # represents what the verifier reviewed against — not a since-edited, uncommitted spec (v0.27 P0). This same
    # check must also hold BEFORE the codex-judge is dispatched (so it reads the committed frozen contract).
    CONTRACT_PATHS=( ".parallax/$SLUG/spec.md" ".parallax/$SLUG/slices.md" ".parallax/$SLUG/validation.md" ".parallax/$SLUG/slices.lock" )
    if ! git -C "$ASSEMBLED" diff --quiet HEAD -- "${CONTRACT_PATHS[@]}" \
       || [ -n "$(git -C "$ASSEMBLED" ls-files --others --exclude-standard -- "${CONTRACT_PATHS[@]}")" ]; then
      echo "ESCALATE: the frozen contract differs from HEAD in the worktree — the verifier may have read a spec that isn't the committed one"; exit 2; fi
    # CONTRACT_HASH = the frozen normative spec the work is verified AGAINST (spec/slices/validation/slices.lock).
    CONTRACT_HASH=$(bash scripts/contract-hash.sh HEAD "$SLUG" "$ASSEMBLED")
    # merge-ledger stamps policy_hash AND contract_hash, both FROZEN per run; a mid-run change => exit!=0 => PARK.
    # --repo-root (v0.37.3 F4) anchors the fingerprint's file component to the ASSEMBLED tree's tracked
    # files, so a verifier round that echoes a basename ("StorageSubscreen.test.tsx:882") where round 1
    # recorded the repo-relative path still binds to the SAME finding — no phantom duplicate, no
    # already-fixed finding re-opened by path drift. An ambiguous basename is kept distinct with a loud
    # path_warnings entry (never silently merged); treat such a warning as a round-quality problem to fix.
    # v0.38 5.3 (gate A4) — $RAW_VERDICT is the VERBATIM provider output the judge persisted for THIS
    # round (role-codex-judge saves it BEFORE returning). merge-ledger schema-validates the round,
    # requires raw == round, persists it as reviews/$SID.round<N>.raw.json and records the receipt —
    # a malformed envelope is a PROVIDER ERROR (retry/fallback per the judge's chain), NEVER something
    # to hand-extract a verdict from; there is no pass without a re-readable raw receipt.
    # v0.38 5.2 (gate A5) — --pinned-policy enforces the freeze-time-frozen round budget at ingestion:
    # a round beyond the pinned budget is refused (exit 5) unless a recorded review-budget amendment
    # (contract-amend.py record-budget, human-repeated machine-minted token) widened it. An
    # assumption_recorded or a codex.toml edit is not authority.
    PINNED=".parallax/$SLUG/review-policy.frozen.json"
    RAW_VERDICT="$ASSEMBLED/.parallax/$SLUG/reviews/$SID.round$ROUND_N.raw.json"   # the judge PERSISTED this before returning (role-codex-judge, v0.38 5.3)
    python3 scripts/merge-ledger.py "$LEDGER" "$ROUND_JSON" --slice "$SID" --current-diff "$DIFF" --slug "$SLUG" --pinned-policy "$ASSEMBLED/$PINNED" --raw-response "$RAW_VERDICT" --contract-hash "$CONTRACT_HASH" --repo-root "$ASSEMBLED" \
      || { echo "PARK: round refused (malformed/receiptless round, budget exhausted without amendment, or mid-run policy/contract drift) — never hand-author a verdict, never widen by editing codex.toml"; exit 2; }
    python3 scripts/triage.py "$LEDGER" --pinned-policy "$ASSEMBLED/$PINNED" --current-diff "$DIFF"; case $? in   # 0 green / 1 block / 2 escalate
      0) git -C "$ASSEMBLED" add -- "$REL_LEDGER"      # reviewed src+tests already staged by 2b; stage ONLY the receipt. NEVER 'git add -A' (it would sweep in un-reviewed untracked files — v0.22 P0#1). Committing the index = reviewed tree + receipt.
         git -C "$ASSEMBLED" commit -q -m "$SID ${S.id}: green (reviewed tree + review receipt)";;
      1) echo "BLOCK: route each blocker to its fault side, fix, then re-review (FRESH verifier, +1 round)";;
      2) echo "ESCALATE/PARK: escalation queue (finding + Claude's ledgered rebuttal, if contesting)";;
    esac
    ```
    Why this can't be gamed: `merge-ledger.py` is the **only** writer of findings (it maps the verifier's review round into the ledger by fingerprint/id — Claude invents no `id`/`spec_ref`/`evidence`, and a cited id is honored only if its metadata matches that finding's fingerprint); `triage.py` reads the `[review]` policy **only** from the trusted `.parallax/codex.toml` (never the ledger) and **fails closed** (no validator ⇒ `escalate`, never green); and a `fixed` finding counts **only** if the verifier verified it (`verified_by=codex`) against the **current** `--current-diff` — the content hash of the *actual reviewed code+tests* (`git ls-files -s`, not `HEAD^{tree}`), so a fix checked against an earlier tree no longer re-matches. The green commit is **exactly** that reviewed tree plus the ledger receipt: the assembly already staged src+tests, so 2c stages **only** the ledger (`git add -- "$LEDGER"`) and commits the index — never `git add -A`, which would sweep in un-reviewed untracked files, so the promoted commit can't differ from what was verified. Then act on the decision:
       - **`block`** → route each blocker to its fault side with the arbiter's **NL framing** (`code-fault` → coder, `test-fault` → test-writer, `spec-gap`/`safety`/`anti-cheat` → `/parallax:spec` or the human) — never raw verifier text across the blindness wall. After the fix re-greens, **re-review with a fresh verifier**; it regression-checks the ledger first, and `merge-ledger.py` records the new round (+1 `rounds_used`).
       - **`escalate`** → park with the finding. The **one** thing Claude may add to the ledger is a `claude_rebuttal` (`duplicate`/`not-reproducible`/`contradicts-spec`/`out-of-scope`) — and a rebuttal can only **escalate** a blocker to a human, **never** green it; it is never a silent drop.
       - **`green`** (no live blocker: only `low` advisories remain, or every blocker is a codex-verified fix against the current reviewed-tree hash) → committed above (case `0`) as the reviewed tree + ledger receipt; advisories go to the run report (and verbose Telegram), not to a block.
  - **`limit`** (the verifier returns `limit`, meaning **every** provider in its chain was rate-limited — a single provider's limit is handled by falling back to the next, e.g. Codex → z.ai GLM, *inside* the judge) → neither a fault nor a `concerns`: do **not** commit, escalate, or fabricate a pass. Mark the slice `green-unverified` (arbiter passed, verification still owed) and **pause the run** per *Limits, checkpointing & resume* (the judge already did short retries + fallback before returning `limit`). **Evidence (v0.37.3 F5):** append `run_parked` (actor `main`, summary `paused-on-limit: verifier debt owed (green-unverified), service=<svc>, retry_after=<hint>`) via the canonical Step 0.7 call as part of this pause.
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
- **Redispatch envelope (v0.37 P0.1 — keep the wall up under feedback).** An arbiter→track redispatch may carry **only a natural-language fault description anchored to spec refs** (e.g. `spec.md §B10`). It must **never** carry selectors, `file:line`, export/symbol names, exact markup, or implementation structure — *unless that exact detail is already part of the frozen spec*. Leaking the other side's shape through a "fix it like this" hint collapses blindness just as surely as a tracked file would; if the only way to describe the fault is to reveal the other track's code, the real defect is a spec gap → escalate.
- **RED → spec-gap** (test and code each defend a reasonable-but-different reading) → this is the one fault you never settle in code or tests. **Record it as a structured resolution item and park the run for a human decision** — never pick a winner. The arbiter hands you the two competing readings + spec refs (role-arbiter → *Escalation*); give them to the single writer as one queue item (`kind: spec-gap`, the slice id, the `source_contract_hash` + `source_run_id`, the `spec_refs`, a behaviour `question`, and ≥2 `options` each carrying its observable `consequence`) — never hand-editing the JSON:
  ```bash
  python3 scripts/resolution.py add-item ".parallax/$SLUG/resolution-queue.json" --slug "$SLUG" --item-file "$ITEM_JSON"
  ```
  Then checkpoint `run-state.status = needs-resolution` (plus the `resolution_queue` path), commit, and stop this slice — independent slices may still finish (autonomous/parallel). The human runs **`/parallax:resolve <slug>`**, whose decision mints a *new* contract generation and rebuilds the feature against it — never a `/parallax:spec` patch on the old contract, and never a winner chosen here. The structured queue item, not free-text `escalations.md`, is the authoritative source the resolver reads.
- **anti-cheat flagged** → treat as the relevant fault, re-dispatch with the flag made explicit; never accept a green that the arbiter marked gamed.

**Circuit breaker:** if the iteration counter hits 3, **or** the arbiter notes **oscillation** (the same fault returning unchanged), stop the slice and escalate to the human with a STUCK report: the slice, the persistent fault, and what each side tried. Do not keep looping.

## Step 3 — Final whole-feature check
After the last slice greens, run the contract's **full check + lint + typecheck + build** once more on the complete integration tree, **and re-verify that every integration seam in `slices.md` still resolves from its entry point** (a later slice can regress a re-export an earlier seam relied on) — to catch cross-slice regressions at the seams. If red, treat it as a new arbiter pass (route per 2c) for the offending slice. Only an all-green, all-seams-resolve whole feature proceeds.

**Whole-feature invariant sweep (v0.37 P0.3; RECEIPTED from v0.38 D2).** Per-slice green can still miss cross-file defects, so before completion also run `python3 scripts/feature-sweep.py --slug "$SLUG" --receipt` against the integrated tree — the `--receipt` flag is not optional prose-polish: it writes `.parallax/$SLUG/sweep-receipt.json` (schema `assets/sweep-receipt.schema.json`, binding the verdict to the sha256 of the exact `invariants.json` swept), and `finalize-gate.py` **refuses completion without that committed receipt** — a `run_completed` summary saying "feature-sweep clean" is attestation, not proof (the RUN1 gap). Also append a `feature_sweep` evidence event (actor `main`, the receipt path in `--artifact-paths`) via the Step 0.7 helper. It executes the concrete invariant classes the spec recorded in `.parallax/<slug>/invariants.json`: forbidden PII / trust / anti-cheat or money patterns that must not reach shipped code, a shared field with **no live consumer** (a dead field/seam), and any **I/O-heavy slice whose tests are mock-only** that ships neither an integration/contract check nor the explicit `externals mocked -> integration unverified` stamp. A violation (exit 2) or a missing manifest (exit 3) blocks completion. This is a concrete-invariant gate, **not** a broad style or architecture review.

**Sanctioned mechanical contract-tightening (v0.37 P0.4).** If a real run uncovers a *determinate* mechanical under-scope after freeze (the spec left exactly one correct reading implicit — no product fork, no unresolved ambiguity, no choice between competing behaviour readings), do **not** edit the frozen spec in place and do **not** reach for the heavier `/parallax:resolve`. Record an amendment with `scripts/contract-amend.py record …` under `.parallax/$SLUG/amendments/`: it carries the evidence, a pre-freeze pass on the *delta*, and an all-true amendment-propagation check (examples, acceptance, public-interface, blast-radius, validation, slice-seams), and bumps the `contract_hash`. `contract-amend.py verify` then accepts the new frozen bytes **only** through that sanctioned chain — **any** post-freeze contract change with no valid amendment chain fails the mechanical guard, and freeze/finalize accept only bytes that hash-match a pass / acceptable low-notes review snapshot.

## Step 4 — Finalize, pin, push, advance (automatic, only after full green)
After Step 3 is green: **finalize the completion receipt first**, then **pin the verified commit as an immutable OID** and use that *same OID* for the gate **and** every push. Pinning closes a TOCTOU — checking a symbolic ref and then pushing it lets the branch move to an unverified commit B between check and push, sending B to the epic (v0.25 P0#1) — and it keeps the remote feature from lagging the commit that enters the epic (the receipt is added *before* the feature push, v0.25). We never push broken code; the arbiter's verdict + the gated receipt are the gate. **Order (v0.37.2 — the remote feature push is gated by `finalize-gate.py`):** commit the terminal receipt/evidence bundle → CAS-update the *local* feature ref → pin `VERIFIED_OID` → run `finalize-gate.py` on it → and **only if the gate passes** push the feature branch at that same OID; on a hold nothing is pushed and the epic is not advanced. The feature push, the epic gate, and the epic push all use the one immutable `VERIFIED_OID`, and no push is ever forced.
```bash
PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"   # same as Step 1
TIP_REF="${PREFIX}$SLUG"
TIP=$(git -C "$ROOT" rev-parse "$TIP_REF")
# (a) Finalize the feature-level receipt ON the feature ref. Autonomous/parallel leaves $ROOT DETACHED, so a
#     plain `git commit` would land on detached HEAD — never on feature/<slug> — and the gate would read
#     status!=complete and HOLD a correct run (v0.24 P1#3). Build the receipt in a TRANSIENT detached worktree
#     on the tip and advance the branch by a CAS update-ref, exactly like parallel integration.
FWT="$(dirname "$ROOT")/.parallax-wt/$SLUG-finalize"
git -C "$ROOT" worktree add -q --detach "$FWT" "$TIP"
VT=$(bash "$ROOT/scripts/code-tree-hash.sh" HEAD "$FWT")
# In $FWT, write the TERMINAL bundle in ONE commit (v0.37.1 freshness — finalize-gate.py binds all of it;
# it touches only .parallax/, so $VT is unmoved). Order matters:
#   1. drain verifier/arbiter debt (done before Step 4);
#   2. set run-evidence.json run.status="complete";
#   3. append a terminal run_completed event (same run_id+slug) to events.jsonl;
#   4. sha256 the two committed-intended evidence files;
#   5. write run-state.json status="complete", verified_tree="$VT", a fresh ISO updated_at, and a
#      completion receipt {completed_at (ISO), run_id, verified_tree="$VT", run_evidence_sha256,
#      events_jsonl_sha256, terminal_event:"run_completed"};
#   6. commit the whole bundle so the receipt and the bytes it hashes are the same committed object.
# A present-but-unbound updated_at is NOT freshness: freshness means the terminal run-state, terminal
# evidence, the run_completed event, and the verified code tree all match.
RE=".parallax/$SLUG/evidence/run-evidence.json"; EV=".parallax/$SLUG/evidence/events.jsonl"
# v0.37.3 F5 — steps 2+3 of the order above are EXPLICIT helper calls, written INTO $FWT so the
# terminal status + run_completed event land in the same one commit finalize-gate.py sha256-binds
# (never appended after the fact). EVD_FWT points at the finalize worktree's evidence dir:
EVD_FWT="$FWT/.parallax/$SLUG/evidence"    # RUN_ID as Step 0.7
# --transcript-path (v0.38 D3): the session .jsonl ITSELF when derivable — never the container
# dir (the RUN2 defect), never invented; omit the flag when genuinely unknown.
python3 scripts/evidence-event.py update-run "$EVD_FWT" --status complete \
  --run-id "$RUN_ID" --slug "$SLUG" --feature-tip "$TIP" --dirty-at-end false
python3 scripts/evidence-event.py append "$EVD_FWT" --run-id "$RUN_ID" --slug "$SLUG" \
  --event-type run_completed --actor main \
  --summary "run complete: all slices integrated and verified" --artifact-paths '{}'
RE_SHA=$(sha256sum "$FWT/$RE" | cut -d' ' -f1); EV_SHA=$(sha256sum "$FWT/$EV" | cut -d' ' -f1)
# ... write $FWT/.parallax/$SLUG/run-state.json with status=complete, verified_tree=$VT, completion{ run_evidence_sha256=$RE_SHA, events_jsonl_sha256=$EV_SHA, terminal_event=run_completed } ...
# v0.38 D2 — the receipted sweep is part of the terminal bundle finalize-gate checks:
python3 scripts/feature-sweep.py --repo "$FWT" --slug "$SLUG" --receipt \
  || { echo "HOLD: whole-feature sweep violation/missing manifest — cannot finalize"; exit 2; }
( cd "$FWT" && git add -- "$RE" "$EV" ".parallax/$SLUG/run-state.json" ".parallax/$SLUG/sweep-receipt.json" \
    && git commit -q -m "$SLUG: run complete (terminal completion receipt; evidence + sweep receipt bound)" )
git -C "$ROOT" update-ref "refs/heads/$TIP_REF" "$(git -C "$FWT" rev-parse HEAD)" "$TIP"   # CAS: lands the receipt on feature even when $ROOT is detached
git -C "$ROOT" worktree remove --force "$FWT"
# (b) PIN the verified commit as an immutable OID — gate THIS and push THIS, never the moving ref.
VERIFIED_OID=$(git -C "$ROOT" rev-parse "$TIP_REF")
# (c) STANDALONE FINALIZE GATE on the pinned OID — runs BEFORE any push, so the remote feature push is
#     GATED by finalize-gate.py (v0.37.2 ordering fix). On a hold, NOTHING has left the machine.
if ! python3 scripts/finalize-gate.py --feature-ref "$VERIFIED_OID" --slug "$SLUG"; then
  echo "HOLD: finalize gate failed (missing arbiter receipt / evidence / a green-unverified slice / unbound-or-stale run-state freshness) — feature NOT pushed; epic NOT advanced. Parking an epic-hold escalation."
  exit 0
fi
# (d) Push the FEATURE branch AT the pinned OID — reached ONLY after finalize-gate.py passed; the remote
#     feature == exactly what the gate checked and what may enter the epic (no lag). NEVER --force.
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$ROOT" push origin "$VERIFIED_OID:refs/heads/$TIP_REF"
else
  echo "No 'origin' remote — $TIP_REF is ready locally at $VERIFIED_OID; push manually."
fi
```
- Never force-push. If the remote rejects (non-fast-forward on a re-run), report it and stop — do not overwrite remote history.
- **Product-copy hold.** If any slice in this feature created or changed strings the spec marked as **product copy** (user-facing wording — dictionary text, labels, bot/UI messages), stop **before** advancing the epic and get an explicit human OK on the *words*. A green build proves the copy is wired correctly, not that it says the right thing; wording is a product decision, not an engineering one. (Numbers inside those strings are already constant-sourced per the money checklist — only the language needs sign-off.) Keep the feature out of the epic until approved.

**Standalone finalize gate (v0.37 P0.2 + P1.5).** Before any feature push or epic advance, run the single mechanical gate `python3 scripts/finalize-gate.py --feature-ref "$VERIFIED_OID" --slug "$SLUG"`, so completion never rests only on ideal Step-4 behaviour. It reads the committed ref and **holds** unless: the run-state is present, schema-valid, `complete`, and **fresh** — bound by a terminal `completion` receipt (v0.37.1) whose `updated_at`/`completed_at` are real ISO timestamps and whose `run_evidence_sha256` / `events_jsonl_sha256` / `verified_tree` match the committed evidence bytes, the recomputed code-tree hash, and a same-run `run_completed` event in `events.jsonl`. A present-but-unbound `updated_at` is **not** freshness. It also holds unless: **no slice is `green-unverified`** (owed cross-model verification must be drained first); the required **evidence** artifacts `.parallax/$SLUG/evidence/{run-evidence.json,events.jsonl}` are committed; and **every** slice carries a committed, schema-valid green **arbiter receipt** `.parallax/$SLUG/arbiter/<id>.json` — so the orchestrator can never self-green a slice or fold arbitration inline. It then delegates the deep verifier / contract-hash / verified-tree / frozen-slice-set checks to `epic-gate.py`. A hold parks an *epic-hold* escalation and does **not** advance.

**Verifier-limited continuation (v0.37 P0.2).** A build may legitimately reach `green-unverified` (e.g. paused on a Codex limit) and keep building independent slices, but it must **not** integrate or finalize until the verifier debt is drained — reuse the existing `paused-on-limit` + `paused.service="codex"` semantics; add no new run-state status. **No-codex degradation must be loud:** for any spec touching trust, anti-cheat, money, PII, security, or safety, no-codex mode must **refuse auto-green** and require a clearly labelled interactive hold — never silently treat a Claude-only green as verified, and never weaken the verifier just because it is slow or expensive.

**Session lease (v0.37 P1.5).** A run holds the `run-state.lock` lease (`holder` / `acquired_at` / `expires_at`); a resume refuses to start while a live lease is held by another session and may steal only an expired one, so two concurrent sessions cannot advance the same slug. A resume also reconciles already-`integrated` slices and skips them rather than redoing them.

**Advancing the epic** (after the feature is green, has **passed `finalize-gate.py`**, been pushed, and any product copy is approved) follows the **epic-integration contract** (see Standing rules: invariant / content / transport) — **but first a hard verification gate, because the epic is append-only.** The gate is a **feature-level receipt bound to the actual promoted commit**, computed by `scripts/epic-gate.py` entirely from the COMMITTED feature commit (never the working tree, never a CLI-supplied slice list, never a preset flag). It reads `run-state.json`, the frozen `slices.lock` manifest, every slice ledger **and the `[review]` policy** via `git show <commit>:…`, and requires: `status = complete` and the run-state `slug` == this feature; the run-state slice set EQUALS the frozen `slices.lock` set (no silently-dropped slice); **every** slice `integrated`; each ledger's `slug` + `slice_id` **identity**, its `policy_hash` == the **committed** policy's hash (triaged under the policy that's committed, frozen per run, not a swapped-in permissive one), its `contract_hash` == the **recomputed** hash of the committed normative contract (`spec.md`/`slices.md`/`validation.md`/`slices.lock` — so the spec or validation can't be rewritten after review, v0.26 P0), `rounds_used ≥ 1`, and a GREEN triage under that committed policy; and the run-state `verified_tree` == the **recomputed** code-tree hash of the promoted commit (a code change after review is caught). Any failure ⇒ **hold**: the feature branch is already pushed for human review but the epic is **not** advanced; park an *epic-hold* escalation. Gate the **pinned OID** and advance the epic to that **same OID**:
```bash
# (e) HARD HOLD for EPIC advance: gate the PINNED commit (finalize-gate.py already ran in step (c), before
#     the feature push; this is the append-only epic gate). At THIS point the feature IS pushed for review.
if ! python3 scripts/epic-gate.py --feature-ref "$VERIFIED_OID" --slug "$SLUG"; then
  echo "HOLD: feature is UNVERIFIED per the committed feature-level receipt — feature pushed for review; epic NOT advanced (append-only). Parking an epic-hold escalation."
  exit 0
fi
# (e) Advance the epic to the SAME pinned OID — immutable across the gate->push window (no TOCTOU, v0.25 P0#1).
git fetch origin "<epic>"
git push origin "$VERIFIED_OID:refs/heads/<epic>"   # rejected if NOT a fast-forward — never --force  (epic should share the PREFIX namespace)
# Evidence (v0.37.3 F5): the feature entered the epic — record it (and pr_opened/pr_merged when
# a PR is actually observable, e.g. via gh; absent knowledge stays absent, never invented).
EVD=".parallax/$SLUG/evidence"   # + RUN_ID as Step 0.7
python3 scripts/evidence-event.py append "$EVD" --run-id "$RUN_ID" --slug "$SLUG" \
  --event-type feature_merged --actor main \
  --summary "feature advanced into the epic at $VERIFIED_OID" --artifact-paths '{}'
```
- If that push is **rejected** (`origin/<epic>` has advanced), do a **real merge**: in a transient checkout of `origin/<epic>`, `git merge "$VERIFIED_OID"` (the pinned tip), **run the full validation suite on the merged tree**, then non-force push and tear the checkout down. Never rebase/squash/rebuild to dodge the merge.
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
- **Integrate on green — transactionally, in the slice's assembly worktree.** When a slice clears 2c (arbiter green **and** the post-green verifier, if enabled), apply ONLY its delta (vs the recorded `wave_base` `WB`) **in its own `$WT/S<n>/assembly` worktree**, never the shared `${PREFIX}$SLUG` tree; the delta is taken **from the 2c green commit** — over reviewed code+tests **and** the review receipt (`.parallax/<slug>/reviews/`) — so the **ledger (memory, round budget, codex proof) rides into the integrated commit** instead of being dropped (v0.22 P0#2), and what integrates is exactly what was verified. Advance `${PREFIX}$SLUG` only after the patch applies cleanly:
  ```bash
  AWT="$WT/S<n>/assembly"
  GREEN=$(git -C "$AWT" rev-parse HEAD)                       # the 2c green commit: reviewed src+tests + ledger receipt
  TIP=$(git -C "$ROOT" rev-parse "${PREFIX}$SLUG")            # current integration tip
  ( cd "$AWT" && git switch -q --detach "$TIP"
    # one delta WB->GREEN over code+tests AND the review receipt — so the committed ledger is carried, not lost
    git diff --binary "$WB" "$GREEN" -- "${SRC_PATHSPECS[@]}" "${TEST_PATHSPECS[@]}" ".parallax/$SLUG/reviews/" \
      | git apply --3way --index --binary || {
        git reset -q --hard; echo "CONFLICT: slice S<n> is not independent"; exit 9; }   # transactional: all-or-nothing
    git commit -q -m "S<n> assembled (reviewed tree + review receipt)" )
  # serialize the move of the shared ref (CAS old-value $TIP); on a lost race, re-detach at the new tip and re-apply (the diff is vs WB):
  git -C "$ROOT" update-ref "refs/heads/${PREFIX}$SLUG" "$(git -C "$AWT" rev-parse HEAD)" "$TIP"
  ```
  Three guarantees: **`--binary`** so binary files apply (a plain text diff of a binary fails — `cannot apply binary patch without full index line`); the **assembly worktree** keeps a partial apply (a second-patch conflict) **off** `${PREFIX}$SLUG` — feature is touched only by the final CAS `update-ref`, never left half-patched (`A src/new` + `UU tests/a`); and the **CAS old-value `$TIP`** serializes concurrent integrations (a slice that loses the race re-detaches at the new tip and re-applies its `wave_base` diff). Applying only the delta **preserves slices already integrated this wave**; a `--3way` conflict = two slices touched the same lines → not independent (park / add a dependency edge, never force). Do **not** mirror `src/**`+`tests/**` from one branch (wipes other slices) and **never `git merge`** the blindfold branches. Re-run the seam check + post-green verifier after the ref-update. (Sequential Step 2b mirror is correct; merge stays for **epic** integration.)
- **Isolation caveats.** Concurrent slices must not share a mutable external (one test DB, one fixture file): give each wave-member its own (per-slice DB name/schema), or give them a dependency edge in the manifest so they don't overlap. Per-slice worktrees multiply provisioning cost — **symlinking** deps rather than reinstalling matters here (Step 1 / domain skills).

### Autonomous handling of stops (`--autonomous`)
With no human at the console, every place Steps 2c/3 say *"escalate to the human now"* becomes: **park to a queue and keep going.**

- **Escalation queue** `.parallax/<slug>/escalations.md` — append a row for each: a **spec-gap** (test and code each defensible against the spec), a **circuit-breaker** trip (3 iterations / oscillation), and any **Claude-arbiter ↔ Codex divergence** (post-green or pre-freeze). The affected slice **halts**; other independent slices **keep running their waves**. Autonomy never invents a resolution to a genuine ambiguity — it records it and moves on. For a **spec-gap specifically**, also record a *structured* resolution-queue item (`scripts/resolution.py add-item`) and set `run-state.status = needs-resolution`: that queue item — not the Markdown — is the authoritative source `/parallax:resolve <slug>` later reads, and autonomy **never** resolves it itself (only a human decision mints the next generation). `escalations.md` remains a human-readable projection.
- **Product-copy queue** `.parallax/<slug>/product-copy.md` — strings the spec marked *product copy* collect here for human wording sign-off at the epic → `main` PR; they never auto-ship.
- **No silent green.** A parked slice is not green and is not integrated; it cannot unblock dependents. The run finishes the slices it *can* and then stops — a partial, honest result beats a fabricated one.
- **Verifier required.** Autonomous mode leans on the cross-model verifier as the gate that replaces the human; honor `.parallax/codex.toml` `on_missing` (`refuse` — don't run autonomously without it; or `warn` + stamp every output `UNVERIFIED`). **`warn` is a feature-only license:** an UNVERIFIED run may push the *feature* branch for human review, but it **must not advance the append-only *epic*** — Step 4's mechanical gate (`scripts/epic-gate.py`, computed from the committed receipts) holds it and parks an epic-hold, because `warn` produces no committed ledger for the gate to pass. Only a real verified pass advances the epic automatically; `warn` never does. Either way, **nothing reaches `main` without a human** (epic → `main` is always a PR + CI + review).

### Autonomous report (overrides Step 5)
End with a machine-readable summary a human reads after an unattended or scheduled run: per-slice outcome (**integrated** / **parked + why**), the **escalation queue**, the **product-copy queue**, the **decision-log** carried from the spec, and the **full commit inventory** (Step 5 already requires this — keep flagging side-commits, especially migration edits).

---

## Limits, checkpointing & resume

A long run can exhaust **Claude's** limit (which kills the orchestrator itself) or **Codex's** (which fails the verifier call). Neither must lose progress, and neither is a *fault* — a quota error is transient, never a `concerns` and never an escalation. The run survives by checkpointing eagerly and resuming from the checkpoint on an hourly schedule.

### The checkpoint `.parallax/<slug>/run-state.json`
Written **eagerly** — after every state transition (a slice integrated, parked, a verdict received, a pause) — and committed to `feature/$SLUG`. Eager because a Claude limit kills the process: you can't write at the moment of death, so the last good state must already be on disk. It records (schema: `assets/run-state.schema.json`): the resolved epic base; per-slice `status` (`pending` / `in_progress` / `green-unverified` / `integrated` / `parked`); each slice's iteration counter + attempt history (so the circuit breaker survives a resume); the integrated set; queue paths; run `status` (`running` / `paused-on-limit` / `complete` / `stuck`); and on a pause the `service`, `reason`, and any `retry_after` hint. Per slice it also records the **code/test branch tips (SHAs)**, the **`wave_base`** (the integration tip the slice's tracks forked from — the diff base for parallel integration; required once a slice is `in_progress` or `green-unverified`), the **owed arbiter verdict + verified-diff ref** (for a `green-unverified` slice), and its **wave**; plus a run-level **`lock` lease** (whose object is the unique lock commit, required while `status` is `running`). These make a resume *exact* — continue from the recorded SHA, re-apply the same `wave_base` diff, re-verify the same diff — rather than approximate. **Lease discipline (v0.38 D3 — both live runs carried a vestigial lease):** the lease is real or it is dropped, never decorative. `lock.holder` is the **`run_id`** (the same identity `finalize-gate.py` checks — a session id in holder makes the two disagree); `expires_at` gets a real, non-zero TTL and is **renewed on every checkpoint write** (a lease equal to `acquired_at` is zero-width and protects nothing); a process that notices `now > expires_at` on its own lease must warn and re-acquire before advancing; and the terminal bundle **clears the lock** (`lock: null`) so a completed run holds nothing. It also records each slice's **`review_ledger`** path (`.parallax/<slug>/reviews/<id>.json`); the **`rounds_used` inside that per-slice ledger is the single source of truth** for the review budget (run-state keeps no second counter that could diverge), so a resumed run reloads the findings history and the rounds spent instead of re-discovering them.

### On a limit → pause the whole run
- **Verifier limit** (the `codex-judge` returns `limit` — but **only after exhausting its whole provider chain**: a primary limit first falls back to the next provider, e.g. Codex → z.ai GLM, with no pause): when even the fallback is limited, mark the current slice `green-unverified` (arbiter passed, verification still owed — it is **not** integrated, since integration still requires the verifier), set run `status = paused-on-limit`, checkpoint, and **stop**.
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
2. Re-fetch `origin/<epic>` and re-run the **provenance** check (a resume must still start from the fresh remote tip — Step 0.6). **Then reconcile the checkpoint against git BEFORE trusting any recorded tip (v0.38 6.1 / F7, gate B1) — run-state is a checkpoint, git is the truth:**
   ```bash
   python3 scripts/resume-reconcile.py --repo "$ROOT" --slug "$SLUG" --prefix "$PREFIX" \
     || { python3 scripts/resume-reconcile.py --repo "$ROOT" --slug "$SLUG" --prefix "$PREFIX" --write-back \
            || { echo "PARK: run-state/git drift needs human reconciliation (missing branch)"; exit 2; }
          # write-back adopted the REAL git tips: record the seam, re-commit the checkpoint
          python3 scripts/evidence-event.py append "$EVD" --run-id "$RUN_ID" --slug "$SLUG" \
            --event-type session_handoff --actor main \
            --summary "resume reconciled run-state tips from git (recorded tips were stale across a session boundary)" \
            --artifact-paths '{"run_state": ".parallax/'"$SLUG"'/run-state.json"}'
          git -C "$ROOT" add ".parallax/$SLUG/run-state.json" "$EVD/events.jsonl" \
            && git -C "$ROOT" commit -q -m "$SLUG: resume reconciliation (tips written back from git)"; }
   ```
   The live failure this closes: a handoff recorded S6-test at `ced5b80` as READY while the real branch had advanced **3 commits** (2 arbiter RED rounds + a re-blindfold) — a resumer obeying it verbatim would have rebuilt on an arbiter-rejected tree and silently discarded the diagnosed fixes. Only after exit 0 here, rebuild/verify the per-slice worktrees **at the (now git-true) `code_tip`/`test_tip`**.
3. **Fail fast if still limited:** try one cheap operation; if the limit is still in force, re-checkpoint `paused-on-limit`, **release the lease**, and exit — don't burn quota idling.
4. Otherwise continue from the checkpoint: skip `integrated` slices; for a `green-unverified` slice run **only** the owed verification against its recorded `verified_diff` (don't rebuild it); resume `in_progress` slices from their `code_tip`/`test_tip`; dispatch `pending` slices as their deps integrate. Idempotent — nothing already done is redone. **Evidence (v0.37.3 F5):** the resuming session appends `session_handoff` (actor `main`, summary: what was inherited — resumed-from status, slices already integrated, what continues) via the canonical Step 0.7 call before dispatching anything, so a run that outlived one session leaves a structured seam instead of an ad-hoc gap.
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

---

## Live-run evidence (v0.36 auditability; v0.37.3 F5 — written through the deterministic helper, across the WHOLE build)
Maintain `.parallax/<slug>/evidence/run-evidence.json` (`assets/run-evidence.schema.json`) and the **append-only** `.parallax/<slug>/evidence/events.jsonl` (`assets/run-evidence-event.schema.json`) across the build, stamping `plugin.version` from `.claude-plugin/plugin.json`. These are plugin-run artifacts, not a benchmark result.

**Write events through `scripts/evidence-event.py`, never by hand-assembling JSON (v0.37.3 F5).** Three audited production runs left `events.jsonl` stopped at `spec_frozen` and `run.status` stuck at `frozen-spec` for the entire build — the prose wiring alone didn't survive a real run. The helper validates each event against the schema before appending (fail closed), creates the directory when missing, preserves append-only, and refuses an event whose `run_id`/`slug` don't match the sibling `run-evidence.json`:
```bash
EVD=".parallax/$SLUG/evidence"
python3 scripts/evidence-event.py append "$EVD" --run-id "$RUN_ID" --slug "$SLUG" \
  --event-type slice_dispatched --actor main \
  --summary "S<n> dispatched to both blind tracks" \
  --artifact-paths '{}'
python3 scripts/evidence-event.py update-run "$EVD" --status running --run-id "$RUN_ID" --slug "$SLUG"
```

For `/parallax:run` (`command_entry: "run"`), the call points — every one is a real helper invocation at the moment it happens, not a summary written at the end. **The concrete inline call sites live in the steps themselves** (Step 0.7 bootstrap + canonical append shape; Step 2a dispatch/done-gates; Step 2b arbiter iterations; Step 2c verifier rounds, slice green and the limit pause; Step 4 terminal bundle + feature_merged; *Limits/Resume* session_handoff) — this list is the map, not the only mention:
- at **preflight**: initialize or load `run-evidence.json`, record `repo` (root / branch / base_tip / dirty_at_start), then `update-run --status running` — the build phase must never sit at `frozen-spec` (the exact live-run defect this fixes).
- per **slice dispatch** (every wave): append `slice_dispatched`.
- on the **test-writer** RED done-gate: append `test_writer_red`; on the **blind-coder** done-gate: append `blind_coder_done` (include `--agent-type` / `--branch` / `--commit` / `--worktree` when known).
- per **arbiter iteration** (each 2b→2c cycle, not just the verdict): append `arbiter_iteration_started` when you dispatch the arbiter and `arbiter_iteration_finished` when it reports, then the verdict event `arbiter_green` / `arbiter_red` (with the exact commands + artifact paths the arbiter ran — its role contract already hands you both).
- per **cross-model verifier round**: append `codex_round_started` at dispatch and `codex_round_finished` when the round is merged (name the provider in the summary; put the ledger path in `artifact_paths`), then the verdict event `verifier_pass` / `verifier_concerns`. **Record the round's authorization honestly (P2):** a round taken under a fresh explicit human grant is `human-authorized`; a round the orchestrator continued from a prior result with no new gate is `self-continued` — two different facts, never collapsed into one label.
- on a slice clearing 2c entirely (arbiter green + verifier disposition green): append `slice_green`; in parallel mode also after the CAS integration lands.
- on a **green-unverified pause** (verifier limit — verification owed): append `run_parked` with the pause reason (`paused-on-limit`, service, retry_after) in the summary, and checkpoint per *Limits*.
- on **run parked** (spec-gap → needs-resolution, breaker trip): append `run_parked` and set `run.status` accordingly (`update-run --status needs-resolution`).
- at **finalize** (Step 4a, inside the terminal bundle): `update-run --status complete --feature-tip <sha> --dirty-at-end <bool>` and append the terminal `run_completed` — this is the same terminal event `finalize-gate.py` freshness-checks (v0.37.1), now written by the helper.
- on the **feature entering the epic** (Step 4e push succeeds): append `feature_merged`; if a PR for the feature/epic is opened or merged where the orchestrator can observe it (e.g. via `gh`), append `pr_opened` / `pr_merged` when known — absent knowledge stays absent, never invented.
- on a **session handoff** (context exhaustion → a fresh session resumes the checkpoint): append `session_handoff` from the resuming session, summarizing what was inherited.
- a summary is not proof: when a file/log exists, put its path in the event's `artifact_paths`.
- **`evidence_limits` stays factual (P2):** never assert a transcript/session path is "unavailable" categorically when it merely wasn't captured — record the actual path when it exists, else `null` plus a note of *why* it's absent. An evidence-limits line that overstates unavailability is itself an evidence defect.
