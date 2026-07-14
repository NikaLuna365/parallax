# Provider runtime reference (v0.40)

The provider runtime separates host, role, transport, and model. The frozen
provider contract is a plan artifact, not a replacement for `spec.md`; the
spec remains the sole behavioral source of truth.

## Budget boundary

The runtime does not aggregate provider billing. It records credential
presence, authentication/probe status, availability, limit signals, and budget
observations separately. `--probe-budget` invokes only an explicitly configured
read-only adapter and never sends a coding/review request.

An exact `remaining` value requires `budget_source_class = "official-api"` or
`"official-cli"`, an adapter response marked `exact_balance`, and a numeric
provider value. The
example config maps DeepSeek's official `GET /user/balance` response through
configurable JSON paths. Dashboard, local health, subscription, and generic
limit signals are retained as metadata but are downgraded to `unknown` for
money. z.ai has no configured exact endpoint in this release. Estimates are
labelled estimates and are never compared to an invented balance.

## Continuous limit guard

`provider-runtime.py limit-guard` and dispatch observe a configured
`live_signal_command` or `live_signal_path` at safe boundaries: before a
request, after its response, before commit, and before fallback. A normalized
observation returns exactly one of `continue`, `handoff`, or
`sleep_until_reset`. A warning never interrupts an in-flight child process.

Adapters may normalize Claude Code status-line `rate_limits.*.used_percentage`
and `resets_at`, Codex `/usage`/`status` or status-line data, and Gemini CLI
`/stats model` data. Gemini's own model fallback stays inside Gemini; the
Parallax supervisor owns cross-provider handoff. `codex doctor` is diagnostic
only. Without a machine-readable signal, predictive live status is
`unknown`; explicit limit/auth errors still trigger handoff.

`sleep_until_reset` reports a bounded duration with jitter. The CLI can be
asked to perform that bounded sleep and re-probe; default dispatch returns the
action so the supervisor can cancel, switch provider, or extend the wait. Any
failed edits are reconciled to the exact clean base before handoff or sleep.

When launched from Claude Code/Desktop or Codex/Codex Desktop, the host is the
UX initiator. The local supervisor owns external worker lifecycle,
checkpoints, receipts, fallback, and sleep. Native host turns are not claimed
preemptible without a supported interception point; the runtime reacts after
the host reports a limit.

## Worker boundary

`provider_runtime.py dispatch` accepts a frozen-artifact request with an
explicit visibility manifest. Codex CLI receives a bounded stdin prompt and
workspace-write sandbox flags; Aider receives only explicit `--read` and
`--file` paths and `--no-auto-commits`. Parallax runs the existing
`blindfold-guard.py` before and after each attempt, owns the commit, and
rejects unexpected paths or provider-owned commits.

Fallback is ordered and per-role. A failed attempt with edits can only be
followed by another provider after a disposable worktree is reset to the exact
clean base. If reconciliation is not possible, the role parks. Every attempt
is normalized and can be appended to the existing evidence timeline as a
`provider_attempt` event with host/provider/transport/model identity.

## Codex host seam

`scripts/codex-host.py` dispatches the same request through the same runtime,
blindness check, commit protocol, fallback, attempt log, and host artifact.
It does not claim to implement the full Claude orchestration. Missing frozen
artifacts result in `host_capability_missing` and exit 2.

## OpenRouter and persistent routing state

`openrouter-api` is an optional OpenAI-compatible Aider transport using
`OPENROUTER_API_KEY` and `https://openrouter.ai/api/v1`. Its read-only `/key`
probe is an OpenRouter key budget. `/credits` is attempted only with a
separately configured management credential; `/models` is catalog metadata and
does not retain pricing or raw provider responses. `only`, `order`,
`allow_fallbacks`, model fallbacks, data-retention policy, upstream model, and
upstream provider are preserved in bounded routing metadata. This never
becomes a direct z.ai balance claim.

The direct z.ai `aider-api` example uses the OpenAI-compatible base URL and
Aider 0.86.2's `--yes-always` flag; the obsolete `--yes` flag is not emitted.
The z.ai provider may declare `auth_probe = "zai-models"` with
`auth_endpoint = "https://api.z.ai/api/paas/v4/models"`. This is a built-in
GET adapter, not an arbitrary shell probe, and it runs only with explicit
`--probe-auth` or `--probe-all`. It records only normalized `http_200`,
`http_401`, or `network_failure` status/error classes.

Routing memory lives in a configurable local SQLite database (default
`~/.config/parallax/provider-state.sqlite`) with mode `0600`. Its key includes
provider, transport, one-way credential fingerprint, model/upstream model, and
optional project scope. Explicit z.ai insufficient-balance/402/business errors
persist `exhausted`; the next run skips that identity until reset/recheck and
probes the OpenRouter same-model fallback. Rotating the key changes the
fingerprint. The database is routing memory, not evidence or quota truth.

## Claude/Codex host verification

`scripts/host-verification.py` performs local CLI availability checks and may
run `codex doctor` as a diagnostic-only command. It discards command output and
never turns version, authentication, or doctor status into quota evidence.
Claude `rate_limits.*.used_percentage`/`resets_at` and Codex `/usage`,
`/status`, status-line, or app-server observations remain unknown until a
machine-readable host signal is emitted. Host checks and optional host smoke
records are separate from provider API evidence; the static harness reports
`host_smoke_not_safe` unless a one-attempt, non-editing path is explicitly
confirmed.
