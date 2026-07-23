# Parallax

> **Independent paths. One verified result.**

A spec-driven, blind-coder TDD pipeline (Claude Code plugin). *Code and tests look at one specification from independent vantage points; their divergence reveals the hidden defect — like parallax: two lines of sight on one object expose its true depth.*

A maximally-concrete, **read-only spec** drives two **independent** tracks — a test-writer and a blind coder that never sees the tests — and a single whole-seeing **arbiter** loops with failure analysis until green, then integrates and pushes. An optional, structurally-independent **cross-model verifier** (Codex, with a z.ai GLM or Gemini fallback) reviews the spec before the blind tracks and each green slice after.

## v0.40 provider runtime

The executable provider core lives in `scripts/provider_runtime.py`. Copy
`assets/providers.toml.example` to `.parallax/providers.toml` for shareable
provider/role definitions; put keys only in ignored `.parallax/.env`, legacy
`.parallax/zai.env`, or `~/.config/parallax/providers.env`.

Use `python3 scripts/provider-runtime.py preflight --repo .` during planning.
It reports command/key presence and read-only probe status without printing
secrets. Add `--probe-budget` only when a configured read-only budget adapter is
intended to run. Budget reports preserve `known`, `unknown`, `limited`, and
`unavailable`; `unknown` is never converted to zero or unlimited.

Budget provenance is explicit. A configured official adapter (API or exact
provider CLI) may report a timestamped balance; the example maps DeepSeek's
official `GET /user/balance`. Gemini dashboard or project-quota observations,
z.ai usage/dashboard information, Claude
subscription limit/reset signals, and Codex local auth/health remain
informational and do not become a personal dollar balance. Every observation
keeps source class, confidence, and timestamp.

During dispatch the local supervisor observes optional live signals at safe
boundaries: before request, after response, before commit, and before
fallback. It returns `continue`, `handoff`, or `sleep_until_reset`; it never
preempts an in-flight provider process. Configure a read-only
`live_signal_command` or `live_signal_path` for host signals such as Claude
Code status-line `rate_limits.*.used_percentage`/`resets_at`, Codex `/usage` or
`/status`, or Gemini CLI `/stats model`. Without a machine-readable signal,
predictive status is explicitly `unknown`; explicit limit/auth errors remain
the fallback trigger. Gemini's model-level fallback stays inside Gemini CLI;
cross-provider handoff belongs to this supervisor.

### v0.40.2 Codex adapter

Codex CLI and the Codex desktop/IDE surfaces can install Parallax as a
skills-only plugin through a configured marketplace. The Codex adapter uses
the same repository contracts, provider runtime, limits tooling, and
fail-closed gates. Claude slash commands are not exposed as Codex commands;
start a new Codex thread after installation so the bundled skills load.

### v0.40.3 Z.ai/Aider authentication fix

Direct Z.ai workers using Aider now map the registry's `ZAI_API_KEY` into
Aider's required `OPENAI_API_KEY` child-process variable. OpenRouter keeps
its separate credential path.

### v0.40.4 Aider startup hardening

Direct OpenAI-compatible providers use Aider's required `openai/<model>`
namespace, and Aider runs with `--no-gitignore` so startup does not alter the
worker repository's `.gitignore`.

### v0.40.1 passive limits and OpenRouter

Use `python3 scripts/provider-runtime.py limits`, `limits z.ai`, or the exact
alias `limit`. `--json` is validated by `assets/provider-limits.schema.json`;
`--watch N` repeats read-only collection and marks the last snapshot stale on
failure. The command never starts inference. Arbitrary `probe_command` values
are skipped unless the registry says `probe_policy = "explicit"`, the adapter
declares `probe_read_only = true`, and `--probe-auth`/`--probe-all` is passed.

Each worker attempt refreshes `.parallax/<slug>/runtime/limits.snapshot.json`
and `limits.context.md` at safe boundaries. The short envelope is passive:
the supervisor applies thresholds and fallback, while the worker is told not
to spend a request checking limits. Aider receives one explicit `--read` file;
Codex receives the fixed prefix; the native host gets the same request context.

The optional `openrouter-api` transport uses only `OPENROUTER_API_KEY` and
`https://openrouter.ai/api/v1`. Its official `/key` probe is an OpenRouter
key-level budget, not a direct z.ai balance. `/credits` is used only when a
separate management credential is explicitly configured; `/models` is a
read-only catalog signal. Routing (`only`, `order`, `allow_fallbacks`, model
fallbacks) and the data-retention policy are recorded in receipts/context.
OpenRouter and direct `ZAI_API_KEY` credentials are never mixed, and upstream
identity is preserved when OpenRouter serves a `z-ai/*` model.

Routing memory is local SQLite (`~/.config/parallax/provider-state.sqlite` by
default, configurable with `provider_state_db` or
`PARALLAX_PROVIDER_STATE_DB`). It stores only a one-way key fingerprint and
normalized provider observations; the database is not committed or copied to
evidence. Direct z.ai `glm-5.2` can carry an operator-declared `$7` estimate
labelled `operator-estimate`, never exact balance. An explicit z.ai
insufficient-balance/402/business error records `exhausted` for that provider,
transport, fingerprint, model, and scope; the next run skips it and probes the
configured OpenRouter `z-ai/glm-5.2` fallback. Key rotation produces a new
fingerprint. `limits --recheck` clears the selected persistent state.

`python3 scripts/provider-runtime.py plan ...` produces the proposed matrix;
`freeze --plan ... --selection ...` requires explicit confirmation, enforces
each role's `required_capabilities` against every chain provider, and writes
the selected host, role chains, capabilities, provider identities, fallback
policy, and budget limitations without secrets. Worker dispatch owns the
blindfold check and it fails CLOSED: a blind role (blind-coder, test-writer)
must supply `side`+`slug`, the dispatch request itself is schema-validated
before any provider process starts, and a missing or unreadable
`blindfold-guard.py` parks the attempt (`blindfold-guard-unavailable`) instead
of reporting clean. Dispatch further owns the explicit writable-file list,
clean-base fallback reset, commit, normalized attempt receipt, and evidence
identity, and routes by ROLE: the cross-model verifier role only ever reaches
the read-only review path. The Codex-host seam is `scripts/codex-host.py`;
requests missing the frozen artifacts (including `side`/`slug` for blind
roles) park rather than emulating Claude's Task tool.

---

## Quick Start (5 minutes)

### 0. Requirements
| Need | Why |
|--|--|
| **Claude Code** (with plugins) | runs the command/agent/skill contracts |
| **Git** + a real repo with a clean tree | the whole pipeline lives on branches |
| **Python 3.11+** and `pip install jsonschema` | the deterministic `scripts/` + the disposition gate (fails closed without `jsonschema`) |
| *optional* **Codex** / **Gemini** CLI, or a **z.ai (GLM)** API key | the cross-model verifier (opt-in; without it you get Claude-only gates) — z.ai needs no CLI, just `ZAI_API_KEY` in the env |
| *optional* Telegram bot | progress notifications for autonomous runs |

### 1. Install
```text
/plugin marketplace add NikaLuna365/parallax
/plugin install parallax@parallax
```
Then `/help` should list `/parallax:spec`, `/parallax:run`, `/parallax:auto`. (Reopen Claude Code if they don't appear.)

### 2. Create a specification
Run this **inside the git repo you want to build in**:
```text
/parallax:spec Add token-bucket rate limiting to the REST API
```
Parallax brainstorms with you **read-only** (asks one question at a time), then freezes three artifacts at a human-OK gate. **You'll see** a short Q&A, then: *"spec frozen on `feature/<slug>` — run `/parallax:run` to build it."*

### 3. Run the build
```text
/parallax:run rate-limiting           # the <feature-slug> from step 2
```
**You'll see** per-slice progress: the blind test-writer and blind coder are dispatched, the arbiter runs your real test/lint/build commands and loops on red with failure analysis, each slice goes green, the feature branch is pushed, and a final report lists every commit since the epic base.

### 4. Inspect the result
```bash
git branch --list 'feature/*'                 # feature/<slug> (+ track branches)
git log --oneline feature/rate-limiting       # what was built
ls .parallax/rate-limiting/                    # spec.md slices.md validation.md slices.lock run-state.json ...
cat .parallax/rate-limiting/run-state.json     # status: complete / paused-on-limit / stuck
```
**Success looks like:** `feature/<slug>` exists with green slices, `run-state.json` `status` is `complete`, and (if the verifier is on) every slice has a committed `reviews/<slice>.json`.

### 5. Reset / delete a failed run
Nothing here touches `main`. To wipe a run and start over (replace `SLUG`):
```bash
SLUG=rate-limiting
git switch main                                       # get off the feature branch first
rm -rf "../.parallax-wt/$SLUG" && git worktree prune  # blind-track worktrees live OUTSIDE the repo
git branch -D $(git branch --list "feature/$SLUG*")   # feature + track + per-slice branches
git update-ref -d "refs/heads/feature/lock/$SLUG" 2>/dev/null  # cloud lock ref, if any
rm -rf ".parallax/$SLUG"                               # spec, ledgers, checkpoint, queues
```

---

## What gets created

```
your-repo/
├─ src/ … tests/ …                      # the code+tests the blind tracks produced
└─ .parallax/
   ├─ codex.toml                        # (optional) cross-model verifier config — you create this
   └─ <feature-slug>/
      ├─ spec.md                        # the frozen, read-only source of truth (WHAT, not HOW)
      ├─ slices.md                      # how the work splits + each slice's domain & dependencies
      ├─ validation.md                  # the REAL commands: full/fast test, lint, typecheck, build
      ├─ slices.lock                    # machine-readable frozen slice set (gate checks against it)
      ├─ run-state.json                 # checkpoint: per-slice status, integrated set, resume info
      ├─ feature-state.json             # per-feature ledger across contract generations (safe completion)
      ├─ resolution-queue.json          # structured parked spec-gaps awaiting /parallax:resolve
      ├─ resolutions/<batch>.json       # applied human-decision receipts (one-time token, old→new contract)
      ├─ reviews/<slice>.json           # per-slice cross-model review ledgers (if the verifier is on)
      ├─ history/generation-<N>/        # the previous generation's contract/run-state/reviews (after a resolve)
      ├─ escalations.md                 # autonomous: genuine ambiguities parked for a human
      └─ product-copy.md                # autonomous: user-facing wording awaiting sign-off
```
Branches: `feature/<slug>` (the result) plus disposable track branches (`feature/<slug>-code` / `-test`, or per-slice `…-S<n>-code/-test` under `--parallel`). Worktrees are created **outside** the repo under `../.parallax-wt/<slug>/`.

## Two ways to run it

**Interactive (default)** — you stay in the loop:
```text
/parallax:spec Add a CSV export endpoint     # brainstorm → freeze (you approve the gate)
/parallax:run csv-export                      # build, arbitrate to green, push
/parallax:run csv-export --parallel           # independent slices build concurrently in DAG waves
```

**Autonomous (headless)** — no human at the console; requires the cross-model verifier configured:
```text
/parallax:auto ./briefs/csv-export.md         # spec → build end-to-end, parked items go to a queue
/parallax:run --resume csv-export             # hourly resume after a usage-limit pause
```
In autonomous mode the human gates are replaced by the independent verifier; anything genuinely ambiguous is **parked** to `.parallax/<slug>/escalations.md` instead of guessed. Nothing reaches `main` without a human (epic → `main` is always a PR + CI + review).

## Safe completion — resolving a parked spec-gap
A parked run is a **safe stop, not a failure**: when a blind test and a blind implementation each defend a *different reasonable reading* of the spec, Parallax refuses to guess and stops with `run-state.status = needs-resolution`. That product choice is the one thing it can't decide for you — `/parallax:resolve` is how you supply it.

```text
/parallax:resolve <slug>            # show the open decisions and decide them, one at a time
/parallax:resolve <slug> --status   # just list what's parked (read-only)
```

- **`--resume` ≠ `/parallax:resolve`.** `--resume` only continues a run that **paused on a usage limit** — same contract, same generation. `/parallax:resolve` handles a **contract decision**: it changes the spec, so it mints a **new contract generation** and rebuilds.
- **Only real contract choices.** The resolver decides a spec-gap / under-specified behaviour / rescope. A circuit-breaker trip, an anti-cheat or safety flag, a plain code/test fault, or a provider limit are **not** "human exceptions" — it shows them and names the right path instead. Your options per decision: pick an offered behaviour, give your own rule, explicitly drop it from scope, or abandon the feature. There is no "ship anyway".
- **A decision rebuilds the feature.** After you confirm by repeating an **exact one-time token**, Parallax fully invalidates the old certification and starts fresh against the new contract: a fresh epic base, all slices `pending`, the old code/tests **gone from the active tree** (the blind workers never see them), a fresh pre-freeze review, then `/parallax:run` again. Deliberately thorough — "completed" means "verified against what you actually decided".
- **Where it lives.** Receipts under `.parallax/<slug>/resolutions/`; the structured queue is `resolution-queue.json`; the per-feature ledger is `feature-state.json`; the previous generation's contract/run-state/reviews are archived under `.parallax/<slug>/history/generation-<N>/`.
- **The token is a consent marker, not a signature.** It records that an explicit decision was made; it is not cryptographic proof of *who* typed it. As everywhere, `epic → main` is still a human PR + CI.
- **Continuing a cloud run.** A laptop-off run that parks can be continued without a live session: prepare the decision out-of-band and pass it with `/parallax:resolve <slug> --from-file <decision.json>` (it must carry the exact token + a valid decision — this is not autonomy deciding for you).
- **Older runs.** A v0.30 feature is migrated on first resolve (idempotently); if only a free-text `escalations.md` survives with no structured source, the resolver fails closed and asks you to start a fresh `/parallax:spec` rather than guess.

## Architecture fitness (part of `/parallax:spec`)
Right after the affordance review, `/parallax:spec` runs a narrow **Architecture Fitness** check on the *chosen* shape and records it in the frozen spec. It targets the maintainability failures a behavioural gate can't see — a **wrong seam** (tests/code through internals instead of the public boundary), a **shallow pass-through wrapper**, **duplicated business logic**, a **speculative adapter/port** with no current variation, a **missing regression seam** (tests that stay green while the behaviour breaks), or a silently-violated local **`AGENTS`/`CONTEXT`/ADR**. It is **not** an architecture review and makes no claim to "good architecture": it blocks **only** on a concrete maintainability consequence — never on taste, naming, folder layout, or speculative future flexibility — and it never forces a deep module onto a small feature. A `/parallax:resolve` new generation gets a fresh fitness check automatically (the old one stays in `history/`).

## Project scouts on large repos (inside `/parallax:spec`)
On a **large or unfamiliar** repo, `/parallax:spec` can optionally fan out a few **bounded, read-only internal scouts** to gather evidence before it decides — one scout per lens (existing seams, local architecture contracts, testing/validation seams, source-of-truth/domain logic, risky integrations). This is **not** a new command and **not** a repo-wide audit: scouts only *collect cited evidence* (`file:line`, confidence, uncertainty) and **decide nothing** — they can't edit files, ask you, freeze, or run anything. The main `/parallax:spec` agent **verifies the key evidence itself** (opens the cited lines, confirms a seam is really public, re-confirms a command is real) before using it in the Existing Affordance Review, Architecture Fitness, or `validation.md`. On a small repo, or when the runtime has no sub-agents, fanout simply isn't used — the **linear flow stays the default**, and the frozen spec records whether scouts ran under `## Project scout evidence`. (Whether fanout actually improves large-repo specs is a hypothesis for targeted evals, not a guarantee.)

## Brief packet & AI-architect handoff (no new command)
Parallax also works as a **strict worker** inside a larger flow, where a user and an AI-architect have already brainstormed and hand Parallax a brief. `/parallax:spec --from-doc <brief>` and `/parallax:auto <brief>` accept a structured **Parallax Brief Packet** (`references/parallax-brief-packet.md`) — Problem, Desired behavior, Constraints, Proposed shape, Existing evidence, Open decisions, Non-goals, Validation hints, Risk notes — or plain markdown, which Parallax normalizes into the same shape. There is **no new command**.

The brief is **input, not authority.** Any *Proposed shape* is a **hypothesis**, not an instruction: Parallax still runs the Existing Affordance Review, Architecture Fitness, validation-realism, and the pre-freeze gate, and can **reject** the proposed shape on the evidence. Two honest outcomes:

- **build-ready** → the brief checks out and Parallax freezes the normal artifacts (the spec's `Intake source` section records how the brief was interpreted); or
- **not build-ready** → Parallax returns a bounded **Intake Response** — a `Status`, a one-paragraph summary, **≤5 concrete blocking questions** (each with why it blocks, options, and a safe `recommended default` or `none`), the repo evidence it checked, the assumptions it can safely make, and the next action — and **does not start the build**. The upstream AI/user answers by updating the brief packet and rerunning.

Intake never offers an `ignore` / `ship anyway` path, never asks for a fact the repo can answer, and doesn't change the direct `/parallax:spec <idea>` flow. (Whether the handoff layer measurably improves outcomes is a hypothesis for a targeted eval, not a claim.)

## When *not* to use Parallax
- **Trivial / throwaway changes** where writing a concrete spec costs more than the change.
- **Exploratory / research code** where the spec is the thing you're still discovering — there's no stable source of truth to converge on yet.
- **No executable validation** — if you can't give real test/lint/build commands, blind TDD has no gate to converge against.
- **You can't separate WHAT from HOW** — Parallax's leverage is two independent reads of one *behavioral* spec; if the spec can only be expressed as an implementation, the wall of blindness buys nothing.

## Common setup errors
- **`jsonschema not importable` / the gate escalates everything** → `pip install jsonschema` (on PEP-668 systems: `pip install jsonschema --break-system-packages`). The disposition gate **fails closed** without it.
- **`codex` / `gemini` not found** → the verifier is opt-in. Either install the CLIs (names vary by version) or leave `enabled = false` in `.parallax/codex.toml` for Claude-only gates.
- **"working tree not clean" / "not a git repo"** → `/parallax:run` needs a clean tree in a real git repo.
- **Commands don't appear** → confirm the marketplace was added and the plugin installed/enabled, then reopen Claude Code.
- **Cloud routine push rejected** → cloud runs push only to `claude/*`; set `[git] branch_prefix = "claude/"` in `.parallax/codex.toml`.

---

## The cross-model verifier (opt-in)
Copy `assets/codex/codex.toml.example` to `.parallax/codex.toml` and set `enabled = true`. A minimal config:
```toml
enabled    = true
points     = ["pre_freeze", "post_green"]   # review the spec before, and each green slice after
mode       = "split"                         # split | panel | sole — who holds the verdict
on_missing = "refuse"                        # autonomous: refuse to run with no working verifier (or "warn")
timeout_s  = 600

[git]
branch_prefix = "feature/"                    # set "claude/" for cloud (laptop-off) routines

[primary]
provider = "codex"
form     = "cli"
model    = "gpt-5.5"                           # confirm against your installed `codex`

[fallback]                                    # codex → z.ai GLM (HTTP API — no CLI needed)
provider = "zai"
form     = "api"
model    = "glm-5.2"
base_url = "https://api.z.ai/api/paas/v4/chat/completions"
key_env  = "ZAI_API_KEY"                       # env-var NAME; put the key in untracked .parallax/zai.env and `source` it
# (Gemini instead: provider="gemini" form="cli" model="gemini-3-pro")

[review]
pre_freeze_max_rounds = 2                     # spec-adversary rounds, then a human checkpoint
max_rounds            = 2                     # review rounds per slice, then PARK (no endless loops)
block_severities      = ["medium", "high"]  # low = advisory; medium/high block
always_block_kinds    = ["safety", "anti-cheat", "spec-gap"]
```
The verifier runs a **provider chain** of non-Claude models; on a primary rate-limit it falls back to the next, and only if all are exhausted does the run pause and resume later. **Secrets (tokens, API keys) live in env vars named by the config — never in the file** (`SECURITY.md`). Without this file the pipeline runs exactly as before (Claude-only gates).

Why it's trustworthy (producer-proof, all documented in the contracts):
- Pre-freeze rounds pass through `scripts/pre-freeze-budget.py`: raw schema-valid verdicts, per-round contract snapshots/hashes, counts, and the policy hash live under `.parallax/<slug>/reviews/`. At the cap, autonomy parks; an interactive extension requires an exact human token and grants one round only.
- Each review is a **fresh** verifier (no anchoring session); findings persist across rounds in **per-slice committed ledgers** (`.parallax/<slug>/reviews/<id>.json`) so fixes are re-checked for regression, not re-discovered.
- `scripts/merge-ledger.py` is the **only** writer of findings — Claude authors none; `scripts/triage.py` disposes **mechanically**, reading policy **only** from the trusted `.parallax/codex.toml`.
- A `fixed` finding counts **only** if the verifier verified it (`verified_by=codex`) against the current tree, and the `[review]` policy + the frozen spec are **hashed into each receipt**; `scripts/epic-gate.py` re-checks them against the actual promoted commit before a feature may advance the append-only epic — so the producer can't certify itself, and the spec/policy can't be swapped after review.

## Honesty note
This plugin **is** a set of **prompt contracts** — `commands/`, `agents/`, `skills/` — executed by Claude, plus `assets/` (JSON schemas, a config template), deterministic `scripts/`, and a `tests/` self-test harness. It is **not** a standalone binary. A config option is "implemented" only insofar as a contract branch or a script actually consumes it; see `CHANGELOG.md` for what is mechanically enforced vs. a model-executed directive. The `tests/` harness exists precisely so these contracts don't silently drift.

## Scheduling & running with the laptop off
Three ways to run on a cadence (per Claude Code docs):

| | Cloud (web routine) | Desktop / Cowork task | cron / `/loop` |
|--|--|--|--|
| Runs with the laptop **off** | **Yes** (Anthropic cloud) | No — skips, runs on wake | No |
| Local files | No — **fresh clone** | Yes | Yes |
| Min interval | 1 hour | 1 min | 1 min |

For an **overnight / laptop-off** autonomous run, use a **Claude Code web scheduled task**. Because it's a fresh cloud clone:
1. **Plugin in the repo** (or installed via the routine setup) so `commands/`/`agents/`/`skills/` are present.
2. **Setup script** = `scripts/cloud-setup.sh` — a **best-effort** install of the `codex`/`gemini` CLIs (adjust the package names for your versions if they differ) + project deps + `jsonschema`, and a secret-presence check.
3. **Secrets** in the routine **Environment variables** (codex/gemini keys, `PARALLAX_TG_*`, git push creds) — never in the repo (`SECURITY.md`).
4. **Branch policy:** set `[git] branch_prefix = "claude/"` so the whole run stays in the allowed `claude/*` namespace.
5. Prompt the routine with `/parallax:auto <brief>` (or `/parallax:run --resume <slug>` for the hourly resume).

## Testing the plugin itself
```bash
pip install jsonschema      # required for full schema + gate validation
bash tests/run.sh           # the plugin's own regression harness (executes the real mechanics)
```
The harness **executes** the invariants (git assembly/integration, the lock, the disposition gate, schema validation, `bash -n` on every fenced block) rather than grepping for strings. `tests/verify-codex.sh` / `tests/verify-gemini.sh` confirm the real `codex` / `gemini` CLIs on **your** machine.

## Evaluation harness v2 (measurement — no new command)
From v0.35, Parallax's *outcome quality* (false-green, overbuild, wrong-seam, scout/intake behaviour) is measured by a separate **evaluation harness v2** under `bench/harness_v2/`, **outside the plugin** — record/fixture/aggregate schemas, static maintainability metrics, aggregation, internal fixtures, and pilot adapters that calibrate against SWE-bench / Aider / Code Review Bench. It is **not** part of the runtime and adds **no command**; the plugin's behaviour is unchanged. v0.35 is measurement *infrastructure*, not a benchmark result — see `references/evaluation-harness-v2.md` and `bench/harness_v2/README.md`. No "Parallax is better" claim is made without raw per-run records (that is the v0.36 benchmark).

## Live-run evidence (v0.36 — auditability, not a quality claim)
From v0.36, every `/parallax:spec`, `/parallax:run`, `/parallax:auto`, and `/parallax:resolve` leaves **structured, plugin-version-stamped evidence** under `.parallax/<slug>/evidence/`: a `run-evidence.json`, an **append-only** `events.jsonl` timeline, and optional `e2e-checks.jsonl` and `defect-loop.jsonl` ledgers. This makes a real run **auditable from first-class artifacts** instead of being reconstructed from a Claude transcript — a transcript path is recorded only as *auxiliary provenance*, never as proof. It is **auditability**: **not a benchmark** result, external calibration, or quality claim, and it adds **no command** (the existing commands write it). See `references/live-run-evidence.md`. *(v0.36.1 tightens the four evidence schemas so they mechanically require the minimum fields — `artifact_paths` on every event, the `run-evidence` repo/artifacts/capabilities/limits shape, and the full `defect-loop` chain — with `null` where data is unavailable; a schema-strictness fix only, no behaviour change.)*

## Runtime governance hardening (v0.37 — mechanical gates, not a quality claim)
v0.37 turns safety-critical rules that previously relied on orchestrator discipline into **mechanical gates**, with **no new command** and **no benchmark or quality claim**. Four deterministic, harness-executed checks: a **blindfold guard** (`scripts/blindfold-guard.py`) fails closed when implementation or compiled output leaks into the test worktree, or tests leak into the coder worktree, re-checked per wave; a **standalone finalize gate** (`scripts/finalize-gate.py`) refuses feature push / epic advance unless every slice has a committed green arbiter receipt, no slice is `green-unverified`, the run evidence is committed and the run-state is fresh (delegating the deep checks to `epic-gate.py`); a **whole-feature invariant sweep** (`scripts/feature-sweep.py`) catches cross-file PII / money / dead-seam / mock-only violations a per-slice green misses; and an **auditable contract-tightening guard** (`scripts/contract-amend.py`) rejects any post-freeze contract edit that is not a sanctioned, evidence-backed mechanical-tightening amendment that bumps the contract hash. Every v0.31–v0.36.1 boundary is preserved; the mechanical-vs-directive split is documented in `references/runtime-governance.md`. *(v0.37.1 hardens the finalize gate's freshness: run-state carries a terminal **completion** receipt — `completed_at`, `run_id`, `verified_tree`, and the sha256 of the committed `run-evidence.json` and `events.jsonl`, plus a `run_completed` event — required once `status` is complete, and `finalize-gate.py` recomputes those hashes and the code-tree hash from the committed ref and matches them, so "fresh" means the terminal state, evidence, event and verified tree all agree, not merely a non-empty `updated_at`.)* *(v0.37.2 corrects the `/parallax:run` finalization order so the remote feature-branch push happens **only after** `finalize-gate.py` passes on the pinned `VERIFIED_OID`, with a harness guard that fails if the push appears before the gate.)*

## Live-run reliability hardening (v0.37.3 — a fix pass from three production runs, not a quality claim)
v0.37.3 remediates the confirmed findings from **three real production monorepo runs** (a pnpm workspace; all three features shipped and merged, none passed clean — the findings are recorded verbatim in `references/live-run-audit-findings.md` and are a **findings list, not benchmark evidence**). **No new command, no benchmark / quality / market / production-readiness claim**; every v0.31–v0.37.2 boundary preserved. What changed: the **blindfold guard gains a slice-scoped monorepo mode** (a schema-validated per-slice scope manifest keeps sibling-package roots and the existing base tree resolvable on the test side while the slice's own new/changed implementation still fails closed; a whole-tree allowlist is schema-rejected; `.parallax/**` and ordinary `bin/` scripts stop false-positiving); **pre-freeze closure is mechanical** (`pre-freeze-state.json` carries a `closure` only `scripts/pre-freeze-budget.py` can move to `independent-pass`, and only on a schema-valid verifier `pass` — an orchestrator/human self-attestation can never certify a freeze, and plain `--from-doc` without `--autonomous` unambiguously keeps the human OK gate); the **review-ledger merge is path-stable** (`--repo-root` canonicalizes a basename echo to the same tracked file as round 1 — no phantom duplicates; ambiguous basenames stay distinct, loudly); **run-phase evidence is first-class** (`scripts/evidence-event.py` appends schema-valid arbiter-iteration / codex-round / slice-green / PR / merge / handoff events and moves `run-evidence.json` off `frozen-spec`, so the timeline no longer stops at `spec_frozen`); frontend seams carry a **user-reachability class** and the arbiter demands **interaction proof** — not router membership — for a `user-reachable` seam (a directive, honestly: the harness locks its presence, not a live model's obedience); and the **codex-judge transport** is hardened (`codex exec … < /dev/null` canonical, top-level-`allOf` schemas reach providers as a stripped copy while the full schema stays the acceptance bar, and a silent timeout is never classified as a rate limit).

## Governance self-attestation hardening (v0.37.5 — mechanical gates, not a quality claim)
Two real v0.37.4 production runs (one COMPLETE `--autonomous --from-doc` backend port with a zai/GLM verifier; one RUNNING interactive bot build with the real Codex CLI — **a findings list, not benchmark evidence**) confirmed the v0.37.3 remediation held: no false-green, no unsafe completion, build-phase events decisively fixed, and the cross-model verifier caught real safety/money defects the whole blind chain + arbiter passed GREEN on both runs. They also showed the **self-attestation pattern F3 targeted recurring in three shapes the mechanics didn't cover** — so v0.37.5 mechanizes them, fail-closed: an `--autonomous` run **cannot freeze through the interactive human-OK branch** (`pre-freeze-budget.py freeze-check` demands `closure.status=independent-pass`; mode is pinned into the state; `grant-one` refuses under autonomous; `on_missing=warn` no longer licenses an autonomous freeze); the **round budget is pinned at spec-freeze** (`review-policy.frozen.json`) and every gate evaluates against the **pin** — editing `codex.toml` clears nothing, and widening happens only through a recorded review-budget amendment with a human-repeated machine-minted token; **post-green verifier verdicts are receipted** — every round persists the verbatim provider verdict (`reviews/<slice>.round<r>.raw.json`), the ledger carries sha256 receipts, and a malformed envelope is a provider error, never material for a hand-authored pass. Plus: resume state is reconciled against git (**git is the truth** — stale tips refuse or write back with a `session_handoff` seam); a whole-feature seam must be proven through the **production consumer path** (a test-authored duplicate is not a consumer); the feature sweep is **receipted** (`sweep-receipt.json`, required by the finalize gate); and the OpenAI-strict schema shim needs zero hand-tuned retries while the FULL schema stays the acceptance bar. **No new command, no capability, no benchmark / quality / production-readiness claim**; every v0.31–v0.37.4 boundary preserved. The one measurement gap stays honest: the true cross-package monorepo blindfold case is fixture-proven but not yet exercised by a real run — owed to the v0.37.5 soak, not claimed.

## Adopt & multi-session continuity (v0.38 — a capability, claims stay design-intent until soak)
`--resume` recovers a **clean** limit-pause. v0.38 adds `/parallax:run --adopt <slug>` (and `/parallax:auto --adopt`) for the other case: a run that **died mid-build** in one session — `status=running`, never a clean pause, with in-flight **background** tracks whose completion notifications never crossed the session boundary (the v0.37.4 RUN2 story, where an operator had to hand-write `RUN-HANDOFF.md` and do manual git archaeology). Adopt reconstructs the truth **git-first** from a new per-slug **dispatched-subagent manifest** (`.parallax/<slug>/subagents.json`, written at dispatch), the v0.37.5-reconciled checkpoint, and `events.jsonl`; it **reaps** in-flight background branches (reading the commit off git in place of the missed notification), **re-dispatches only genuinely-missing tracks blind**, and **fails closed** — it refuses a live lease held by another session, escalates irreconcilable state to `.parallax/<slug>/escalations.md`, and **never** fabricates a track or marks a slice done without its arbiter/verifier receipts. A machine-generated `.parallax/<slug>/handoff.md` (deterministic, no operator free-text) **replaces** the hand-written handoff. This is a **capability** release: the mechanics are harness-proven (gates M1, A1–A5, H1, E1), but **public claims stay design-intent until a production soak exercises adopt on a real interrupted run**. `--adopt` is a **flag**, not a new command; it consumes the v0.37.5 F7 git reconciliation rather than re-implementing it; no auto-push to `main`; every v0.31–v0.37.5 boundary preserved. See `references/runtime-governance.md` (resume-vs-adopt) and `references/live-run-evidence.md` (the `subagents.json` + generated `handoff.md` artifacts).

## Gate reachability in the real environment (v0.39 — hardening; hand-driven & monorepo)
The v0.31→v0.38 arc turned three generations of prose rules into **mechanical, fail-closed gates** (harness 176/0). The first true multi-package **monorepo** soak showed the gates are real in code but **un-exercised in production**: every run was **hand-driven** (integrated by hand, verdicts hand-committed, no `events.jsonl`, no `merge-ledger`/`triage` gate), because monorepo ergonomics push operators out of the skill flow — and the detached-HEAD hazard gate B1 mechanizes actually bit a run and was caught by a human, not the machinery. v0.39 makes the gates **fire on the real box**, without a new command. A **hand-driven / degraded finalize** (`/parallax:run --finalize <slug>`, a flag on the done-gate — or auto-detected on a hand-integrated slice) routes the hand path through the same fail-closed gates: it emits the adopt-critical evidence + runs `audit-slice` (fail-closed, HG1), routes a hand-committed post-green verdict through the `merge-ledger`/`triage` schema-gate (HG2), and refuses a stale tip (HG3). **Monorepo silent-failure guards** stop the friction that causes the hand-driving: a **zero-match blindfold `git rm` fails closed** (no silent un-blindfolded tree on a `src/`-prefixed workspace), and a **pre-push guard** (`git fetch` + `merge-base --is-ancestor` + `branch == HEAD`) mechanizes the detached-HEAD / moving-`main` checks operators did by hand. Plus **CI/lint parity** (a validation-contract `ci_equivalent` whole-tree form so local-green == CI-green), a fail-closed fix for a new impl file absent from `protected_impl_paths` under a broad dep-glob, done-gate telemetry regeneration, and CLI foot-gun fixes. **No new command, no new behavior thesis, a clean skill-flow run is byte-identical to v0.38.1; the public "gates protect production" claim stays out until one clean monorepo skill-flow (or adopt) soak runs.** See `references/runtime-governance.md`.

## Adopt & multi-session continuity (v0.38 — a capability, claims stay design-intent until soak)
`--resume` recovers a **clean** limit-pause. v0.38 adds `/parallax:run --adopt <slug>` (and `/parallax:auto --adopt`) for the other case: a run that **died mid-build** in one session — `status=running`, never a clean pause, with in-flight **background** tracks whose completion notifications never crossed the session boundary (the v0.37.4 RUN2 story, where an operator had to hand-write `RUN-HANDOFF.md` and do manual git archaeology). Adopt reconstructs the truth **git-first** from a new per-slug **dispatched-subagent manifest** (`.parallax/<slug>/subagents.json`, written at dispatch), the v0.37.5-reconciled checkpoint, and `events.jsonl`; it **reaps** in-flight background branches (reading the commit off git in place of the missed notification), **re-dispatches only genuinely-missing tracks blind**, and **fails closed** — it refuses a live lease held by another session, escalates irreconcilable state to `.parallax/<slug>/escalations.md`, and **never** fabricates a track or marks a slice done without its arbiter/verifier receipts. A machine-generated `.parallax/<slug>/handoff.md` (deterministic, no operator free-text) **replaces** the hand-written handoff. This is a **capability** release: the mechanics are harness-proven (gates M1, A1–A5, H1, E1), but **public claims stay design-intent until a production soak exercises adopt on a real interrupted run**. `--adopt` is a **flag**, not a new command; it consumes the v0.37.5 F7 git reconciliation rather than re-implementing it; no auto-push to `main`; every v0.31–v0.37.5 boundary preserved. See `references/runtime-governance.md` (resume-vs-adopt) and `references/live-run-evidence.md` (the `subagents.json` + generated `handoff.md` artifacts).

## Command reference
- **`/parallax:spec <idea>`** *(or `--autonomous --from-doc <brief>`)* — idea → frozen spec + slice manifest + validation contract, stopped at a gate. Includes an **Existing Affordance Review** so it reuses an existing seam instead of freezing a needless new subsystem, and a lightweight **Architecture Fitness** check that catches obvious maintainability failures (wrong seam, shallow wrapper, duplicated logic, speculative adapter, no regression seam, ignored local ADR) before freeze — blocking only on a concrete consequence, never on style. On a large or unfamiliar repo it can optionally fan out bounded read-only **project scouts** to gather evidence it then verifies itself (no new command; linear flow stays the default).
- **`/parallax:run [slug]`** *(`--autonomous` · `--parallel` · `--resume` · `--adopt` · `--finalize`)* — build each slice blind, arbitrate to green, integrate, push. `--resume` continues a clean limit-pause; `--adopt` recovers an **uncleanly**-interrupted run (session/context death mid-build) git-first from `subagents.json` + the reconciled checkpoint; `--finalize` (v0.39) routes a **hand-driven/monorepo** slice through the same fail-closed gates (evidence + post-green verdict + stale-tip) so they fire on the real box. All fail closed on irreconcilable state.
- **`/parallax:auto <brief>`** *(`--resume <slug>` · `--adopt <slug>`)* — autonomous end-to-end driver, headless and schedulable. Accepts a Parallax Brief Packet; if the brief isn't build-ready it stops with an **Intake Response** (bounded blocking questions) instead of building.
- **`/parallax:resolve <slug>`** *(`--status` · `--item <R-id>` · `--from-file <decision.json>`)* — turn a parked spec-gap into a verified **safe completion**: decide the contract ambiguity, mint a new generation, fully invalidate, and rebuild. Not `--resume` (that only continues a limit-pause).

## Layout
```
.claude-plugin/   plugin + marketplace manifests
commands/         /parallax:spec, /parallax:run, /parallax:auto, /parallax:resolve
agents/           arbiter, test-writer-*, blind-coder-*, codex-judge (dispatched by name)
skills/           parallax-core, role-*, domain-*  (the operating contracts)
assets/           codex/ schemas + codex.toml.example, run-state + slices-lock + feature-state + resolution-queue/receipt + subagents (v0.38) schemas
scripts/          pre-freeze-budget.py, triage.py, merge-ledger.py, epic-gate.py, resolution.py, resume-reconcile.py, adopt-reconcile.py + subagent-manifest.py + render-handoff.py (v0.38), generation-restart.sh, hashes, cloud-setup.sh
references/        bundled testing-anti-patterns reference
tests/            run.sh + t_*.sh git scenarios + smoke helpers
```
