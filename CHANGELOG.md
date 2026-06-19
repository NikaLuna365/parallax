# Changelog

All notable changes to the Parallax plugin. Versions are cumulative.

## 0.19.0 — third-audit remediation (cloud-lock race, transactional parallel integration, exact-resume schema)
- **#1 (P0 cloud lock, fixed):** two fresh same-`HEAD` clones used to *both* win the lock — pointing the ref at `HEAD` made the loser's "create" a no-op same-value push. The lock now points at a **unique lock commit** (`git commit-tree` with the `run_id` baked in) and is taken create-if-absent locally / by **`git push --force-with-lease=<ref>:`** in the cloud (push only if the ref is absent on origin). `t_lock.sh` now models the *real* same-HEAD race and includes a guard proving the old same-value approach let both win.
- **#2/#3 (P1 parallel integration, fixed):** each slice integrates in its **own `$WT/S<n>/assembly` worktree** (not the shared `feature/<slug>` tree), **transactionally** — both track patches apply all-or-nothing; a conflict triggers `git reset --hard` so the assembly is abandoned and `feature/<slug>` is **never** left half-patched. Advancing `feature/<slug>` is a **CAS `update-ref`** (old-value = the tip we forked from), serializing concurrent integrations; a slice that loses the race re-applies its `wave_base` diff onto the new tip. New `t_conflict.sh` executes the conflict → rollback → feature-unmoved path.
- **#4 (P1 binary files, fixed):** integration uses **`git diff --binary … | git apply --3way --index --binary`** — a plain text diff of a binary file fails (`cannot apply binary patch without full index line`). New `t_binary.sh` proves the `--binary` path applies (bytes match) and the plain path fails.
- **#5 (P1 exact resume, fixed):** run-state schema now records **`wave_base`** per slice (required once `in_progress`/`green-unverified`), constrains all object ids (`base_tip`/`code_tip`/`test_tip`/`wave_base`/`verified_diff`) to a **hex-SHA pattern**, and conditionally requires **`lock` when `status=running`** and **`paused` when `status=paused-on-limit`**. The harness validates a complete checkpoint and rejects 5 distinct incomplete/invalid ones.
- **#6 (P1 sole verdict, fixed):** the verdict schema gains **`code-fault`/`test-fault`** finding kinds, and `role-codex-judge` documents **sole-mode RED arbitration** (the verifier classifies the fault, a third behavior beyond pre-freeze/post-green) so `mode = sole` is actually expressible in the schema it emits.
- **#7 (P2 branch prefix, fixed):** `${PREFIX}` now drives the **sibling value-scan** (Step 0.6) and the **commit inventory** (Step 5) too — a `claude/` cloud run scans/report `claude/*`, not a hardcoded `feature/*`.
- **#8 (P2 timeouts, made real + honest):** verifier calls are wrapped in a real wall-clock **`timeout "$TIMEOUT_S"`** (`curl --max-time` for the api form); exit 124 → next provider. The contract now states plainly which guards are **mechanical** (timeout, next-provider-on-nonzero) vs **directives the agent executes** (the in-process retry budget, the api-form curl) — the harness can only check the mechanical ones.
- Harness → **25 executable checks** (added binary integration, transactional conflict-rollback, assembly-worktree doc, force-with-lease same-HEAD lock, 5-way schema rejection, verdict kinds, real-timeout wrappers).

## 0.18.0 — renamed to Parallax
- Symbolic rename `tdd` → **Parallax**: the plugin `name`, the `/parallax:spec` · `/parallax:run` · `/parallax:auto` namespace, the `.parallax/` artifact dir, the `parallax-core` skill, and `PARALLAX_*` env-var names. Slogan: **Independent paths. One verified result.** — two independent lines of sight on one spec, whose divergence exposes the hidden defect. No behavior change; the methodology is still TDD.

## 0.17.0 — second-audit remediation (parallel data-loss + executable harness)
- **P0 (data loss, fixed):** parallel slice integration applies the **per-slice diff** (`git diff wave-base..tip | git apply --3way`) onto the integration tip, instead of mirroring `src/**`+`tests/**` from one slice branch — which silently deleted every *other* already-integrated slice of the wave (reproduced with 2 slices). Sequential Step 2b mirror is unchanged (correct there).
- **P0 (cloud, fixed):** `branch_prefix` applied **everywhere** — preflight switch, Step 2b assembly, arbiter dispatch — not just Step 1/push. A `claude/`-prefixed run no longer dies at `git switch` with `fatal: invalid reference`.
- **P1 (lock, fixed):** the lock ref points at a real object (`$(git rev-parse HEAD)`), not a run-id string (`git update-ref` rejects that); run-id/expiry live in `run-state.lock`; cross-clone mutual exclusion is via `git push` of the ref (server-atomic).
- **P1 (schema, fixed):** run-state now **requires** `run_id`, and conditionally requires `arbiter_verdict`+`verified_diff` for `green-unverified` and `code_tip`+`test_tip` for `in_progress` — an incomplete "exact resume" checkpoint is now rejected.
- **P1 (syntax, fixed):** the provisioning example is valid shell again; a harness check runs `bash -n` on **every** fenced bash block in run.md.
- **#6:** `cloud-setup.sh` actually attempts the CLI installs; README says "best-effort".
- **#7 (sole):** `mode` decides *who judges* before routing — in `sole` the verifier judges **GREEN and RED** (the arbiter only runs checks). Flagged honestly: mode semantics are integration-validated, not unit-tested.
- **#8 (harness):** the harness now **executes** the mechanics (multi-slice integration, the `claude/` prefix cycle, the real lock + cross-clone race, `bash -n`, schema-reject) instead of grepping — which is why earlier "21 passed" coexisted with broken prefix/lock/cloud. 20 executable checks.

## 0.16.0 — laptop-off (cloud) runs + secret hygiene
- **Configurable branch namespace:** `[git] branch_prefix` (default `feature/`, set `claude/` for Claude Code **web/cloud routines**, whose push policy allows only `claude/*`). Consumed by `run.md` (Step 1 branch/worktree setup, Step 4 push, the lock ref) and `spec.md` freeze — so an autonomous run can execute in the cloud **with the laptop off** without loosening branch protection.
- **Cloud setup:** `scripts/cloud-setup.sh` — the routine "Setup script": installs the codex/gemini CLIs + project deps, checks secret presence (never prints values), reminds the prefix.
- **Secret hygiene:** `SECURITY.md` + `.gitignore`. The repo never carries secrets — the config holds only env-var *names*; values come from the shell env (local) or the routine Environment (cloud). README gained a **Scheduling** section (cloud vs desktop vs cron; laptop-off ⇒ cloud web routine).
- Harness → **17 checks** (added `branch_prefix`, `security_no_secrets`, `cloud_setup`); lock test ref aligned to the namespaced form.
- This is enablement + docs, not new pipeline behavior — the local default (`feature/`) is unchanged.

## 0.15.0 — audit remediation (round 2: correctness & honesty)
- **P4 (resume, fixed):** the checkpoint now records per-slice code/test branch **SHAs**, the **owed arbiter verdict + verified-diff ref**, and **wave**; plus a run-level **lock lease**. Resume takes an atomic `refs/parallax/lock/<slug>` (compare-and-swap) so two overlapping hourly resumes can't double-run, and continues from the recorded SHA / re-verifies the same diff.
- **P5 (honesty, fixed):** "blindness" wording downgraded from "provably / physically cannot" to "removed from the working tree" across `parallax-core`, the role contracts, the 6 agent files, and `spec.md`. Added an explicit anti-cheat rule: reaching the hidden side via git (history / other branch / sibling worktree / reflog) is **gaming the gate**. Blindness = enforced separation + discipline, not a hard sandbox.
- **P6 (modes, wired):** `run.md` Step 2c now has explicit branches for `split` (default), `panel` (arbiter **and** verifier both must pass; verifier mandatory), and `sole` (verifier is the judge; arbiter still runs the checks). The `api` provider form is consumed by `role-codex-judge`.
- Harness grew to **13 checks** (added `no_overclaims`, `runstate_lock` with an atomic-CAS mutual-exclusion test, `mode_branches`).
- Deferred (optional v0.16.0): real *physical* track isolation (separate clones per track) if discipline proves insufficient.

## 0.14.0 — audit remediation (foundation + critical bug fixes)
- **P1 (data loss, fixed):** parallel slice integration is now **assembly** (`git rm` globs + `git checkout <branch> -- globs`, as Step 2b), **never `git merge`** of the blindfold track branches — merging them propagated their `git rm tests/` / `git rm src/` commits and silently wiped the tree. Three-level contract clarified: merge is **feature → epic** only.
- **P2 (config, fixed):** `codex.toml.example` reordered so root scalars (`enabled/points/mode/on_missing/timeout_s`) sit above the first `[table]`; previously they were swallowed by `[fallback]`.
- **P3 (tooling, fixed):** `verify-codex.sh` / `verify-gemini.sh` read the JSON via an env var instead of a pipe — the `echo | python3 - <<heredoc` form gave Python empty stdin, so they always failed.
- **P7 (foundation):** added `tests/run.sh` self-test harness (TOML semantics, schema validity, ref integrity, git assembly-correctness, smoke-validation), `README.md`, this `CHANGELOG.md`, `.github/workflows/ci.yml`, and git history.
- Known/deferred (planned v0.15.0): P4 resume completeness + lock, P5 honest "blindness" wording (+ optional real isolation in v0.16.0), P6 wiring `panel`/`sole`/`api` modes.

## 0.13.0 — Telegram notifications
- `[notify]` config + `run.md` Notifications (autonomous flow): Bot API send-only, non-blocking, secrets via env; modes `lifecycle` / `verbose`.

## 0.12.0 — Gemini fallback (verifier provider chain)
- `[primary]` + `[fallback]` providers (codex / gemini, cli / api); fallback-on-limit before pausing. Gemini CLI has no native output-schema → schema embedded in the prompt + self-validated.

## 0.11.0 — limits, checkpoint & resume
- `.parallax/<slug>/run-state.json` checkpoint; `limit` outcome distinct from a verdict; pause-on-limit + hourly `--resume`; `assets/run-state.schema.json`; `[retry]` config.

## 0.10.x — autonomous + parallel
- `/parallax:auto` driver; parallel slice waves over the dependency DAG with per-slice worktrees; autonomous stop-handling (escalation / product-copy queues). (0.10.1: model id refresh to gpt-5.5.)

## 0.9.0 — autonomous spec + pre-freeze adversary
- Autonomous spec phase (`--from-doc`, decision log); Codex pre-freeze spec review replaces the human OK gate.

## 0.8.0 — cross-model verifier scaffolding
- `role-codex-judge` + `codex-judge` agent + verdict/spec-adversary schemas + `.parallax/codex.toml`; post-green verifier wired in; build-dep provisioning.

## 0.1.0–0.7.0 — pipeline hardening (rounds 1–6)
- Arbiter seam + type-narrowness checks; numeric/money, interface, validator, blast-radius, foresight, product-copy, validation-realism spec passes; per-feature `.parallax/<slug>/` namespacing; epic provenance (origin tip, ancestor scan, known-deviations registry); three-level epic-integration contract; dispatch-points-not-paraphrase; migration completeness + guard-test rules; full commit inventory.
