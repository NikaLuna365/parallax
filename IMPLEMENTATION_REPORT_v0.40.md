# Parallax v0.40 implementation report

## v0.40.1 amendment

The v0.40.1 layer adds passive `limits`/`limit` collection, JSON schema
validation, watch-mode stale handling, safe-boundary context injection,
canonical 80/90% threshold policy, final disposable-worktree reconciliation,
and explicit opt-in handling for arbitrary probes. The optional `openrouter-api`
transport is separate from direct z.ai: it uses `OPENROUTER_API_KEY`, the
official `/key` key-budget endpoint, optional separately configured management
credentials for `/credits`, and `/models` catalog metadata. Receipts/context
preserve OpenRouter balance scope, upstream model/provider, routing, and
data-retention policy without claiming direct z.ai balance.

The z.ai research conclusion remains conservative: official docs expose
dashboard billing/rate-limit pages but no proven machine-readable direct
balance endpoint, so direct z.ai `remaining` stays null.

The amended §7.2 adds a chmod-0600 SQLite routing memory with one-way key
fingerprints. Explicit direct z.ai insufficient-balance/402/business errors
persist `exhausted`; a later run skips that exact credential/model identity,
probes OpenRouter's key budget, and routes `glm-5.2` to `z-ai/glm-5.2`. A new
key fingerprint is independent. The operator `$7` value is carried only in
`operator_estimate`/`operator_budget_remaining` with `operator-estimate` and
`estimate-only` labels.

## Shipped mechanics

- Shareable TOML provider registry with ignored local env discovery and secret-value rejection.
- Read-only preflight reports command availability, key presence source, and optional configured probe status without values.
- Provider-neutral budget reports with `known|unknown|limited|unavailable`, source class, confidence, timestamp, limit signals, and estimates. Exact money requires an explicit official API or exact provider-CLI adapter; DeepSeek's configurable `/user/balance` seam is supported. Gemini, z.ai, Claude, and Codex non-exact signals remain unknown for personal dollar balance.
- Explicitly confirmed frozen host/role/provider matrix, capabilities, fallback policy, and budget limitations.
- Codex CLI and Aider/API command construction with bounded prompt input, explicit Aider files, no Aider auto-commit, redacted bounded transport artifacts, and normalized worker receipts.
- Per-role clean-base fallback, partial-edit disposal, provider/host evidence identity, existing blindfold guard calls, commit ownership, and fail-closed parking.
- Continuous safe-boundary limit guard with `continue`, `handoff`, and bounded `sleep_until_reset`; configured live signals are optional and predictive status stays unknown without one. In-flight provider processes are never preempted.
- Codex host worker seam using the same runtime and a documented `host_capability_missing` boundary.

## Not claimed

- No universal billing aggregator or real-money balance is claimed.
- No production provider, billing, or live Codex-host orchestration run was performed by the harness.
- Native Claude/Codex host turns are not claimed preemptible without a supported interception point; the local supervisor reacts after host-reported limits.
- The Codex-host script does not replace the Claude command orchestrator for spec/run/resume/finalization; unsupported orchestration phases park rather than shortcut the gates.

## Verification

`tests/t_provider_runtime.sh`, `tests/t_provider_limits.sh`, and
`tests/t_provider_state.sh` use local fake executables/adapters only. They cover
env redaction, unknown and non-exact dashboard handling, OpenRouter key-budget
and routing separation, explicit Aider paths, matrix freeze, fake Codex commit,
safe-boundary handoff and reset sleep, clean-base fallback after a partial
quota failure, persistent z.ai exhaustion and fingerprint rotation,
attempt/evidence logging, and the Codex-host artifact. Final result:
`tests/run.sh` — **190 passed, 0 failed**; focused provider tests — **OK**;
Python syntax/schema/diff checks — **passed**; `claude plugin validate .` —
**passed**. The original v0.40 harness did not run provider requests; see the
v0.40.1 remediation evidence below for separately recorded read-only probes.

## v0.40.1 remediation evidence (2026-07-14)

### Static/local harness

- R1: `load_registry()` is the shared validated loader for `validate-registry`,
  `preflight`, `plan`, host dispatch, and CLI dispatch; dispatch validates before
  any provider process can start.
- R2: passive `limits`/`limit` never executes arbitrary `budget_command` or
  `probe_command`; explicit read-only opt-in is required. Provider output is
  discarded and never copied into the result.
- R3/R4/R5: OpenRouter uses the version-checked Aider flow with
  `OPENROUTER_API_KEY`, canonical `credits_key_env` management-key separation,
  and normalized raw-free `/models` catalog snapshots.
- R6: `scripts/host-verification.py` checks Claude/Codex availability, runs
  `codex doctor` only as a diagnostic, and keeps host quota evidence unknown
  until a supported machine-readable signal is emitted.
- `tests/run.sh`: **190 passed, 0 failed**; focused provider/state/host tests,
  Python compilation, `claude plugin validate .`, and `git diff --check` passed.

### Read-only live provider evidence

- OpenRouter `/api/v1/key`: transport completed with the ordinary provider key;
  no exact numeric balance was retained, so quota/balance evidence is
  `unknown` and scoped to `openrouter-key`.
- OpenRouter `/api/v1/models`: normalized catalog was available and matched
  `z-ai/glm-5.2`; raw response was not retained.
- Direct z.ai `GET /api/paas/v4/models`: HTTP 200 with normalized
  `authenticated=yes`; response body was not retained. No quota or balance
  inference was made, so exact balance remains `unknown`.

### Host evidence

- Claude CLI availability/version check: passed; Claude `rate_limits` seam is
  documented but not configured in the local registry, so quota evidence is
  `unknown`.
- Codex CLI availability/version check: passed; `codex doctor` returned a
  diagnostic failure, not quota evidence. Codex usage/status/app-server seam is
  documented but not configured; quota evidence is `unknown`.
- Host smoke: `host_smoke_not_safe`; no host inference was run.

### Paid inference evidence

- Not run. Aider **0.86.2** is installed, but the generic Aider CLI has no
  enforceable USD cost cap, so the paid-smoke gate remains fail-closed. No
  inference, commit, push, or real-worktree mutation was performed.
