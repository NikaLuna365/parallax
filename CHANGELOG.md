# Changelog

All notable changes to the tdd plugin. Versions are cumulative.

## 0.15.0 — audit remediation (round 2: correctness & honesty)
- **P4 (resume, fixed):** the checkpoint now records per-slice code/test branch **SHAs**, the **owed arbiter verdict + verified-diff ref**, and **wave**; plus a run-level **lock lease**. Resume takes an atomic `refs/tdd/lock/<slug>` (compare-and-swap) so two overlapping hourly resumes can't double-run, and continues from the recorded SHA / re-verifies the same diff.
- **P5 (honesty, fixed):** "blindness" wording downgraded from "provably / physically cannot" to "removed from the working tree" across `tdd-core`, the role contracts, the 6 agent files, and `spec.md`. Added an explicit anti-cheat rule: reaching the hidden side via git (history / other branch / sibling worktree / reflog) is **gaming the gate**. Blindness = enforced separation + discipline, not a hard sandbox.
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
- `.tdd/<slug>/run-state.json` checkpoint; `limit` outcome distinct from a verdict; pause-on-limit + hourly `--resume`; `assets/run-state.schema.json`; `[retry]` config.

## 0.10.x — autonomous + parallel
- `/tdd:auto` driver; parallel slice waves over the dependency DAG with per-slice worktrees; autonomous stop-handling (escalation / product-copy queues). (0.10.1: model id refresh to gpt-5.5.)

## 0.9.0 — autonomous spec + pre-freeze adversary
- Autonomous spec phase (`--from-doc`, decision log); Codex pre-freeze spec review replaces the human OK gate.

## 0.8.0 — cross-model verifier scaffolding
- `role-codex-judge` + `codex-judge` agent + verdict/spec-adversary schemas + `.tdd/codex.toml`; post-green verifier wired in; build-dep provisioning.

## 0.1.0–0.7.0 — pipeline hardening (rounds 1–6)
- Arbiter seam + type-narrowness checks; numeric/money, interface, validator, blast-radius, foresight, product-copy, validation-realism spec passes; per-feature `.tdd/<slug>/` namespacing; epic provenance (origin tip, ancestor scan, known-deviations registry); three-level epic-integration contract; dispatch-points-not-paraphrase; migration completeness + guard-test rules; full commit inventory.
