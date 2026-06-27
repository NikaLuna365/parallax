---
name: resolve
description: "Turn a PARKED spec-gap into a SAFELY COMPLETED feature. After /parallax:run (or /parallax:auto) stops with status=needs-resolution on a confirmed contract ambiguity, /parallax:resolve <slug> collects the human's explicit decision, mints a NEW contract generation, fully invalidates the old certification, and restarts the blind build from a fresh epic — never reusing old code/tests/ledgers, never a 'ship anyway'. Run this when a run reports a parked spec-gap; it is NOT --resume (which only continues a limit-pause)."
argument-hint: "<feature-slug>   [--status]   [--item <R-id>]   [--from-file <decision.json>]"
---

# /parallax:resolve — turn a safe stop into a safe completion

A parked run is a **safe stop, not a failure and not a completion**: Parallax refused to ship a feature whose contract was genuinely ambiguous. Your job here is to carry the **one thing the machine cannot supply — a human product decision** — into a *new* contract generation, then let the normal pipeline rebuild and re-verify the whole feature against it. You turn a correct `safe-resolution` into a `safe-completion`.

What you do **not** do: you never "ship anyway", never hand-mark a finding `fixed`, never let autonomy decide a product fork, and never reuse the old generation's code/tests/ledgers as evidence for the new contract. The cost of v0.31 is deliberate — a resolved feature is **rebuilt from scratch** against the new spec. That cost is the point: it's what makes "completed" mean "verified against what the human actually decided".

## The boundary — what is resolvable here (and what isn't)
`/parallax:resolve` only handles a **real contract choice**: a spec-gap, an under-specified behavior, a contested divergence whose resolution needs the observable behavior pinned, or an explicit **rescope**. The allowed human outcomes are exactly: **choose one of the offered behaviors**, **give your own concrete rule**, **explicitly drop the behavior from scope (rescope)**, or **abandon the feature**. There is no `ignore`, no `ship anyway`, no manual `fixed`.

**Not every post-freeze gap belongs here (v0.37 P0.4).** `/parallax:resolve` is for a *real contract choice*. A **determinate mechanical under-scope** — the spec left exactly one correct reading implicit, with no product fork and no competing behaviour readings — is too small for a full generation restart: use the sanctioned **contract-tightening** path instead (`scripts/contract-amend.py`, see `/parallax:run` Step 3), which records an evidence-backed amendment, re-runs pre-freeze on the delta, and bumps the `contract_hash` without discarding the build. If there is *any* genuine ambiguity or choice, it is **not** determinate — it comes back here.

These parked reasons are surfaced by `--status` but are **refused** for contract resolution, with the correct next path named instead — they are not "human exceptions": a **circuit-breaker** trip, an **anti-cheat** flag, a **safety** finding with no contract choice behind it, a plain **code-fault**/**test-fault**, or a **provider limit/missing** (that's `--resume`, not resolve). Resolving a safety/anti-cheat finding as a "product choice" is exactly the bypass this command must never become.

## The mechanical core (you never hand-edit the JSON)
Every write to the resolution queue, the batch receipt, and the feature-state generation transition goes through **`scripts/resolution.py`** (the single writer; fail-closed). The append-only git restart goes through **`scripts/generation-restart.sh`** (atomic CAS, never a force-push). You orchestrate these; you do not invent their JSON by hand. Both are exercised by `tests/t_resolution_gate.sh`, `tests/t_resolution_generation.sh`, `tests/t_resolution_race.sh`, and `tests/t_resolution_migration.sh`.

## Step 0 — Locate the feature, migrate if needed, take the lease
1. Resolve the slug from `$ARGUMENTS`. Read `PREFIX` from `.parallax/codex.toml` `[git] branch_prefix` (default `feature/`) and `git switch ${PREFIX}<slug>`.
2. Read `.parallax/<slug>/feature-state.json`. **If it's absent, this is a v0.30 feature** — migrate it once (it's idempotent), then continue:
   ```bash
   SLUG="<slug>"; FS=".parallax/$SLUG/feature-state.json"; RS=".parallax/$SLUG/run-state.json"
   PREFIX="$(awk -F'"' '/^\[git\]/{g=1} g&&/^branch_prefix/{print $2; exit}' .parallax/codex.toml 2>/dev/null)"; PREFIX="${PREFIX:-feature/}"
   if [ ! -f "$FS" ]; then
     BASE=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['base_tip'])" "$RS")
     TIP=$(git rev-parse "${PREFIX}$SLUG")
     CH=$(bash scripts/contract-hash.sh HEAD "$SLUG" .)
     python3 scripts/resolution.py migrate "$FS" --slug "$SLUG" --run-state "$RS" --base-oid "$BASE" --tip-oid "$TIP" --contract-hash "$CH"
   fi
   ```
   If migration **fails closed** (no structured run-state to migrate — only a free-text `escalations.md`), do **not** guess a queue from prose: tell the user the old run can't be safely resolved and to start a fresh `/parallax:spec`. Free Markdown is never an authoritative decision source.
3. Confirm the run is actually parked for resolution: `run-state.status` is `needs-resolution` (a fresh resolve) or `resolving` (resuming an interrupted one). Any other status → stop and explain (`paused-on-limit` is `--resume`; `running` has nothing to resolve yet).
4. **Take the resolution lease.** Use the *same* mutual-exclusion primitive as `/parallax:run` (run.md → *Limits, checkpointing & resume*): a unique lock commit on `refs/heads/${PREFIX}lock/<slug>`, created create-if-absent locally and by `git push --force-with-lease=<ref>:` in the cloud, so a second resolver — or a concurrent run — **refuses** rather than races. A live lease held by someone else ⇒ exit now. Move `feature-state` to `resolving` once you hold it: `python3 scripts/resolution.py transition "$FS" --slug "$SLUG" --to resolving` (after `needs-resolution`).

## Step 1 — Show the open decisions (`--status` stops here)
```bash
python3 scripts/resolution.py status ".parallax/$SLUG/feature-state.json" --slug "$SLUG" --queue ".parallax/$SLUG/resolution-queue.json"
```
List every **open** blocking item. For each, classify it as **resolvable** (a contract choice — proceed) or **not resolvable here** (one of the refused reasons above — show it, name the correct path, and exclude it from the batch). If `--status` was passed, stop after printing this. If `--item <R-id>` was passed, narrow to that one item.

## Step 2 — One decision per item (a behaviour card, never an implementation)
Ask **one question at a time** (use the question tool). For each resolvable item, present its **decision card** — the structured fields the producer recorded at park time, never re-derived from prose:

```text
ID · stage (pre-freeze | build | post-green) · source (arbiter | verifier)
affected slice · spec references
what exactly is undefined
two or more admissible behavioural readings, each with its observable consequence
the dependent slices this blocks
a recommendation (shown, NOT auto-selected)
the source receipt ids/hashes
```

The card describes **behaviour, not implementation** — it carries no test bodies and no code across the blindness wall. The human picks per item: a specific offered behaviour (`choose-option`), their own concrete rule (`custom-rule`), or an explicit `rescope` (drop the behaviour — and note that a rescope only removes it from the acceptance set if the contract explicitly changes; it is never a waiver of an existing check). To drop the whole feature instead: `python3 scripts/resolution.py abandon "$FS" --slug "$SLUG" --human-text "<exact words>"`. **If any blocking item is left without a concrete decision, no new build starts.**

## Step 3 — Build the candidate contract (transient, contract-only)
In a **transient worktree** (so nothing touches the live feature until confirmed), encode the decisions by editing **only** `.parallax/<slug>/{spec.md, slices.md, validation.md, slices.lock}`. Any change to `src/`, `tests/`, or config outside the normative contract **rejects the batch**. The candidate must:

- state the exact chosen behaviour and **remove the ambiguity itself** (rewrite the spec, not a comment beside it); update examples/edge cases, and the slice manifest + validation if the decision changes them;
- **re-run the full spec self-review on the candidate**, including the **Existing Affordance Review** and the **Architecture Fitness** check (`/parallax:spec` Steps 3.5 / 4.5 / 8) — the new generation gets a *fresh* affordance review **and a fresh Architecture fitness section** derived from the current code, never the old generation's (those stay only under `history/generation-N`). A stale generation can never reuse an old generation's architecture/affordance notes to certify new code or tests. **Project Scout evidence is stale by default too:** an old generation's scout reports are history only; the new generation may run a fresh bounded fanout (Step 1.5) if the conditions still hold, but its `## Project scout evidence` must be re-gathered and re-verified — old scout notes can never certify the new generation;
- produce a **new `contract_hash`** and close every open blocking item in this batch. An **empty contract diff** can neither reset a review budget nor mint a generation (the writer rejects it).

## Step 4 — Confirm with an exact, one-time token, then apply atomically
Mint the confirmation token from the old/new contract hashes and show the human the **contract diff + the list of consequences** (which slices rebuild, what becomes covered):
```bash
OLD=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['contract_hash'])" ".parallax/$SLUG/feature-state.json")
NEW=$(bash scripts/contract-hash.sh CANDIDATE_REF "$SLUG" CANDIDATE_WORKTREE)   # the candidate's frozen contract
python3 scripts/resolution.py mint-token --slug "$SLUG" --from-gen "$GEN" --batch-id "$BATCH" --old-hash "$OLD" --new-hash "$NEW"
```
Application is allowed **only** after the human repeats/selects that **exact** token (`PARALLAX-RESOLVE:<slug>:g<N>->g<N+1>:<batch>:<old-prefix>:<new-prefix>`). A vague approval, an answer to a neighbouring question, or "looks good" is **not** consent. Then apply the batch — it writes the receipt, flips the queue items to `resolved`, and advances `feature-state` to generation N+1 with a new `run_id`, **atomically or not at all**:
```bash
python3 scripts/resolution.py apply ".parallax/$SLUG/feature-state.json" \
  --queue ".parallax/$SLUG/resolution-queue.json" --resolutions-dir ".parallax/$SLUG/resolutions" \
  --slug "$SLUG" --batch-id "$BATCH" --source-run-id "$SRC_RUN" --new-run-id "$NEW_RUN" \
  --old-hash "$OLD" --new-hash "$NEW" --token "$HUMAN_REPEATED_TOKEN" \
  --human-text "<the human's exact words>" --decisions "$DECISIONS_JSON"
```
`$DECISIONS_JSON` is a list of `{item_id, decision: choose-option|custom-rule|rescope, …}`. The token is **single-use** and the batch id can't be replayed; a stale source hash, a reused token, or an unclosed item each fail closed. **The token is an auditable consent marker, not a cryptographic signature** — README and CHANGELOG say so plainly.

## Step 5 — Re-review the new contract (it is not pre-approved)
After the human decision but **before** any build: run a full spec self-review, create a **fresh** pre-freeze state with generation-specific identity, and dispatch a **fresh** cross-model pre-freeze review over the **whole** contract (not just the changed paragraph). Old pre-freeze rounds are visible as history but do **not** count for the new contract. A new `high`/`safety`/spec-gap blocker puts the feature **back to `needs-resolution`** — it can never be auto-accepted by the original token. (Honor `pre_freeze_max_rounds` and the budget exactly as `/parallax:spec`.)

## Step 6 — Full invalidation: restart the generation (append-only)
On a clean re-review, restart the feature onto a **fresh epic** with the new contract — the P2 mechanic:
```bash
git fetch origin "<epic>"
git -C "$ROOT" switch -q --detach "${PREFIX}$SLUG"     # branch advances by CAS, not a checked-out worktree
bash scripts/generation-restart.sh --repo "$ROOT" --slug "$SLUG" --epic "<epic>" --remote origin \
  --feature "${PREFIX}$SLUG" --expect-tip "$(git -C "$ROOT" rev-parse "${PREFIX}$SLUG")" \
  --to-generation "$NEW_GEN" --batch-id "$BATCH" --contract-dir CANDIDATE_CONTRACT_DIR \
  --feature-state ".parallax/$SLUG/feature-state.json" --receipt ".parallax/$SLUG/resolutions/$BATCH.json"
```
This drops the old implementation from the active tree (it survives only in ancestry), archives the old contract/run-state/ledgers under `history/generation-<N>`, installs the gen-N+1 contract + feature-state + receipt, and advances the feature ref by an atomic CAS — append-only, never force. The new blind run therefore starts from clean code: **the test-writer gets no old tests, the blind-coder gets no old implementation**, and review budgets begin fresh, bound to the new contract hash. (In v0.31 invalidation is always **all-slices** — no "this slice looks unaffected" optimization.)

## Step 7 — Rebuild
Hand the new generation back to the normal build: `/parallax:run <slug>` (or `/parallax:auto --resume <slug>`). Every slice is `pending`; the arbiter and the cross-model verifier work only against the new generation; the epic gate (`scripts/epic-gate.py`) already requires the promoted run to be the **active** generation, so a stale-generation green ledger can never certify the new contract.

## Autonomous mode — surface, never decide
Under `/parallax:auto`, a `needs-resolution` is **never** self-resolved. The driver finishes whatever independent slices are still safe, checkpoints, sends a `needs-human` notification (Telegram if `[notify]` is on), prints `/parallax:resolve <slug>`, and parks. It never creates a decision, a token, or a new generation. **`--from-file <decision.json>` does not make this autonomous** — the file must carry the exact confirmation token and a valid human decision; it exists only so a human can prepare a decision out-of-band and let a cloud run continue.

## Resume & idempotency
- `--resume` semantics belong to `/parallax:run`/`/parallax:auto`, not here: at `paused-on-limit` they resume the *same* run; at `needs-resolution` they **no-op** and re-print the resolution summary; at `resolving` they check the transaction journal and either finish the atomic apply/restart or roll back the transient state — they never continue a half-applied generation.
- Re-running `/parallax:resolve` after a crash is safe: nothing moves the feature ref until the final CAS in `generation-restart.sh`. A crash before it leaves the old parked generation untouched; a crash after it is recognized and no-ops. The result is always **either** the old parked generation **or** a fully-formed new one — never a half-built green.

## Honest scope
Mechanical and harness-locked: the queue/receipt/feature-state writes and their fail-closed checks (`resolution.py`), the append-only restart + CAS (`generation-restart.sh`), and the generation-aware epic gate (`epic-gate.py`). Directives you execute: presenting the token to the human and reading their reply, building the candidate contract, and running the fresh self-review + pre-freeze. The token proves *explicit consent was recorded*, not *who typed it*; `epic → main` remains a human PR + CI, as everywhere else in Parallax.

---

## Live-run evidence (v0.36 — auditability, not a benchmark)
`/parallax:resolve` (`command_entry: "resolve"`) maintains `.parallax/<slug>/evidence/run-evidence.json` + the **append-only** `events.jsonl` (`plugin.version` stamped). When a **live defect** becomes a new assumption/resolution item — the GPI A12 pattern — append `defect_found` and `assumption_recorded`, and record a first-class `.parallax/<slug>/evidence/defect-loop.jsonl` entry (schema `assets/defect-loop.schema.json`) connecting: the observed defect → its `source_evidence` (path:line or log ref) → the spec/assumption change → the test-writer RED → the blind-coder fix → the arbiter/test result → any live re-verification. When the resolved generation runs, **connect the old and new run ids** in `run-evidence.json` so the resolution chain is auditable. Live e2e results belong in `.parallax/<slug>/evidence/e2e-checks.jsonl` (`assets/e2e-check.schema.json`) and are structured evidence, **not** a hidden oracle.
