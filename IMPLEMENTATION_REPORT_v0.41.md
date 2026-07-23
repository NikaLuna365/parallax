# Implementation report — v0.41.0 Provider-Runtime Containment

Implementer: claude-worker, per `TZ_v0.41_provider_runtime_containment.md`.
Base: `f075698` (0.40.7) → commits `701b8da`, `96caafe`.

**This report certifies nothing.** Per `IMPLEMENTATION_VERIFICATION_PROTOCOL.md`
§5 and TZ §11, the only acceptance gate is the independent verifier's durable
verdict in `REVIEWS/v0.41_implementation_verification.md`; the release-gate
script refuses to package without it (and refuses a FAIL verdict).

## Scope delivered

- **§5.1 blindness wall fails CLOSED.** `_blindfold` requires side+slug for
  `blind_coder`/`test_writer` (role contract `ROLE_BLINDFOLD_SIDES`), parks
  `blindfold-request-incomplete` on any missing/mismatched field, parks
  `blindfold-guard-unavailable` when `blindfold-guard.py` is absent/unreadable.
  `"not-requested"` survives only for `arbiter`/`cross_model_verifier` by
  explicit exemption. The dispatch REQUEST is schema-validated
  (`assets/worker-request.schema.json`) before any provider process starts;
  `codex-host.py` requires `side`/`slug` for blind roles. Gates BW1–BW4 in
  `tests/t_provider_containment.sh`.
- **§5.2 role routing + capabilities.** Dispatch routes by role class;
  `cross_model_verifier` only ever reaches the read-only review path; a
  non-review-api or write/shell provider parks `unsafe-provider-chain`.
  `required_capabilities` enforced at freeze and at dispatch. Registry
  validation rejects write/shell providers in a declared verifier chain on
  every entrypoint. Reviewer success requires a schema-valid verdict + raw
  receipt; null verdict/empty artifacts is a failure; CLI/host exit codes are
  non-zero for every non-success status. `assets/providers.toml.example`
  verifier chain and `DEFAULT_CHAINS` no longer carry codex/gemini. RC1–RC3.
- **§5.3 cost safety.** `PAID_RESPONSE_CLASSES` + `_paid_response_failure`:
  a failed attempt on a completed paid HTTP-200 stops the chain (default
  `paid_retry_policy = "never"`); `"one-changed-body"` allows exactly one
  retry, identical bodies refused pre-network via request fingerprint
  (`identical-retry-forbidden`), retries recorded with prior error class,
  usage (missing = `"unknown"`, never zero), changed parameters, reason.
  `automatic_fallback=false` truncates to the declared head;
  `fallback_policy="disabled"` stops `_route_chain` widening. Skill/agent
  retry wording corrected. CS1–CS3.
- **§5.4 validated loader + probe gating.** `limit-guard` routes through
  `load_registry` (R1). `live_signal_command` gated exactly as
  `probe_command` (policy + `probe_read_only` + explicit opt-in), never in
  passive `limits`, no secret in env without `live_signal_needs_key = true`,
  execution recorded in snapshot limitations. `source_class` capped at the
  registry declaration (`_cap_source_class`). Value-shaped secrets
  (`Bearer …`, `sk-…`, key prefixes, private-key blocks) rejected by
  `_secret_values` regardless of key name. LG1–LG3.
- **§5.5 child credential isolation.** `run_attempt`, done-gates, blindfold
  guard, `_aider_version`, probe/budget commands, live-signal commands and
  evidence-event children all build env via `_child_env` with `blocked_env`
  covering every registry credential plus `KNOWN_CREDENTIAL_ENV`; a child
  holds only its own provider's key. The pure-function two-key unit test is
  replaced by real per-transport child-process environment assertions
  (codex-cli / aider-api / openrouter-api). CE1.
- **§5.6 insertion-point schema.** `review-runtime.py` selects
  `spec-adversary.schema.json` for `pre_freeze` and `review-round.schema.json`
  for `post_green`; unknown points fail closed; full-schema validation remains
  the bar; a pre-freeze round demonstrably advances
  `pre-freeze-state.json.rounds_used` via `pre-freeze-budget.py record`.
  PF1–PF3.
- **§5.7 reviewer preflight + smoke.** `preflight` emits `review_contract`
  per review-api provider (endpoint, model, thinking, max_tokens, timeout,
  credential class, key presence) with zero network calls; `live-smoke
  --reviewer` performs one cost-capped round-trip against a tiny fixed
  fixture (opt-in `--confirm-spend`, CI-refused, production key refused
  without explicit authorization), reporting finish_reason and usage;
  `blocked` never exits 0. RP1–RP3.
- **§5.8 claims.** README/run.md updated to describe the now-mechanical
  properties; CHANGELOG 0.40.3/0.40.7 false claims carry explicit corrections;
  0.41.0 entry added (TZ §9 text); plugin.json description extended past
  v0.39; marketplace.json narrative restored; RELEASE_REPORT_v0.40.7 smoke
  SHA claim withdrawn (no artifact exists in the repo).
- **§5.9 release gate.** `scripts/release-gate.py check|package` refuses to
  package a version lacking `REVIEWS/v<version>_implementation_verification.md`
  (either vX.Y.Z or vX.Y naming), refuses trivial stubs and FAIL/BLOCKED
  verdicts, and on success builds the zip + SHA256SUMS. PR1 in
  `tests/t_release_gate.sh`.
- **Audit §2 harness blindness closed.** The four neuter probes that left
  v0.40 at 191/0 are now driven: pre-done-gate visibility branch (VM1),
  post-done-gate re-check (VM3), non-disposable dirty park (VM2),
  `provider_diagnostics` plumbing (asserted by CS1/CS1c).

## §5.4.1 — complete registry-entrypoint audit

Every entrypoint that consumes a provider registry, with its loader:

1. `provider-runtime.py validate-registry` — `load_registry`.
2. `provider-runtime.py preflight` — `load_registry`.
3. `provider-runtime.py plan` — `load_registry`.
4. `provider-runtime.py freeze` — consumes plan/selection JSON (no TOML);
   now enforces `required_capabilities` and reviewer-chain read-only rules.
5. `provider-runtime.py dispatch` (CLI) — `load_registry`.
6. `dispatch()` (module entry used by hosts/tests) — `_validate_registry_doc`
   on the passed document.
7. `provider-runtime.py limits` / `limit` — `collect_limits` → `load_registry`.
8. `provider-runtime.py limit-guard` — **was raw `tomllib.loads` (audit
   P0-4, the entrypoint omitted from `IMPLEMENTATION_REPORT_v0.40.md`); now
   `load_registry`.**
9. `provider-runtime.py live-smoke` — `load_registry`.
10. `scripts/codex-host.py` — `load_registry`.
11. `scripts/review-runtime.py` (CLI main) — `load_registry`.
12. `scripts/host-verification.py` — `load_registry`.

Remaining raw `tomllib` uses parse the **codex.toml policy file**, not a
provider registry: `pre-freeze-budget.py:76,499`, `triage.py:69` (out of R1
scope), plus `load_registry` itself (`provider_runtime.py:424`).

## Validation (sandbox, Python 3.10 + `tomli` shim for `tomllib`)

- `bash tests/run.sh` → **192 passed, 0 failed** (190 baseline + containment
  + release-gate; one evidence-schema test conditionally skipped in this
  sandbox, present on a full toolchain).
- `claude plugin validate .` → ✔ Validation passed.
- `python3 -m py_compile scripts/provider_runtime.py scripts/review-runtime.py
  scripts/codex-host.py scripts/release-gate.py` → clean.
- Neuter probes (scratch copies): BW, RC, CS, LG, CE, PF, RP, PR and the
  three audit probes each turned the harness red. Recorded classes:
  `blindfold-request-incomplete` (BW1), `unsafe-provider-chain` (RC1),
  "2 calls" (CS), `live_signal_command executed` (LG2), "child leaked
  ZAI_API_KEY" (CE), `schema-invalid` (PF), preflight AssertionError (RP),
  "packaging proceeded" (PR), VM1 exit-0.

## Not done (by design, §4/§7/§8)

No new public command; no new provider/transport/model; no streaming reviewer
transport; no benchmark or "gates protect production" claim; the `--adopt`
recovery and clean monorepo skill-flow soaks remain **OPEN**; the Codex-host
skill contract parity and roadmap re-sequencing are deferred to their own TZ;
no paid provider call was made anywhere in this implementation or its tests.
