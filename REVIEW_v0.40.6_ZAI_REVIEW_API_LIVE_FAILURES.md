# Review v0.40.6 — paid Z.ai reviewer failures and worker cache guard conflict

Date: 2026-07-14  
Reviewed commit: `79191f2d64cad65fa51954e8a18946cc8e0c5500` (`Parallax v0.40.6`)  
Verdict: **NO-GO for further paid Z.ai retries; remediation release required**

## Executive summary

v0.40.6 correctly removed Aider from the cross-model reviewer path and kept
all three production runs fail-closed. It did not, however, make the direct
Z.ai transport operationally safe enough for unattended use.

The live evidence shows two separate defects:

1. **P0 — the reviewer request leaves GLM thinking enabled by default, ignores
   `reasoning_content`, `finish_reason`, and `usage`, and permits very large
   output budgets.** This can produce paid HTTP-success responses with empty
   `message.content`, or long non-streaming calls that reach the client timeout
   after consuming model work. The runtime then discards the metadata needed
   to tell token exhaustion, reasoning-only output, provider termination, and
   a real network failure apart.
2. **P1 — the editable worker mutation guard treats tool caches created by the
   declared done-gate as unexpected writes.** A valid LinkedIn blind-coder
   correction modified only its allowed source files and report, but `ruff`
   and Python import/compile checks created `.ruff_cache/**` and
   `__pycache__/**`. The runtime parked the attempt as
   `visibility-manifest-violation` and then `partial-edit-not-reconciled`.

The P0 defect is currently spending real API balance without producing a
receipt. Do not resume Photo Bot, CreativeHub, or the next LinkedIn reviewer
round until a patched runtime has passed the acceptance plan in this review.

## What v0.40.6 got right

- Z.ai review is a direct read-only `review-api` transport, not Aider.
- Reviewer capabilities exclude `write` and `shell`.
- Candidate-tree mutation is checked before accepting a response.
- A malformed, empty, timed-out, or schema-invalid response cannot become a
  PASS or replace a raw receipt.
- Raw verdict writes are atomic and full-schema validation remains local.
- Frozen `fallback=false` was respected in every live run.
- Photo Bot and CreativeHub parked without integrating or freezing; LinkedIn
  accepted a real `concerns` verdict and routed findings instead of greening.

These properties must remain invariant in the remediation release.

## Live evidence

### Photo Bot — `search-by-name`, S4 post-green

- Verified candidate: assembly `bf23313`, arbiter GREEN `32ea1b8`.
- Attempt 1: `empty-provider-response`; no raw receipt.
- Bounded attempt 2: `provider-timeout-or-network` at 300 seconds; no raw
  receipt.
- Result: S4 remains `green-unverified`; S5 was not started.
- Evidence:
  - `/home/niko/Desktop/work/2026/Yango/photo-bot/.parallax/search-by-name/runtime/S4/reviewer/attempts.json`
  - `/home/niko/Desktop/work/2026/Yango/photo-bot/.parallax/search-by-name/escalations.md`
  - `/home/niko/Desktop/work/2026/Yango/photo-bot/.parallax/search-by-name/handoff.md`

### CreativeHub — `runtime-auth` pre-freeze

- Attempts 1 and 2: `empty-provider-response`.
- Attempt 3: `provider-timeout-or-network` at 600 seconds.
- All attempts exited 2 without a raw receipt.
- State remained `rounds_used=0`, `next_round=1`, `closure=open`.
- S1-S3 were not started; source/tests were not changed.
- Evidence:
  - `/home/niko/Desktop/work/2026/Yango/creativehub_migration/.parallax/runtime-auth/runtime/pre-freeze-review.provider-failures.json`
  - `/home/niko/Desktop/work/2026/Yango/creativehub_migration/.parallax/runtime-auth/escalations.md`
  - `/home/niko/Desktop/work/2026/Yango/creativehub_migration/.parallax/runtime-auth/reviews/pre-freeze-state.json`

### LinkedIn — `linkedin-selfservice-bot`, S6 post-green

- Attempt 1: `empty-provider-response`.
- Attempt 2 completed after approximately 329 seconds and produced a
  schema-valid `concerns` receipt with three findings.
- This proves that 300 seconds can be too short, but also proves that timeout
  length is not the whole defect: the provider returned empty content before
  timeout in other attempts.
- Evidence:
  - `/home/niko/Desktop/work/2026/Yango/.parallax-wt/linkedin-selfservice-bot/S6/assembly-v0404/.parallax/linkedin-selfservice-bot/reviews/S6.round1.raw.json`
  - `/home/niko/Desktop/work/2026/Yango/.parallax-wt/linkedin-selfservice-bot/S6/assembly-v0404/.parallax/linkedin-selfservice-bot/reviews/S6.json`
  - `/home/niko/Desktop/work/2026/Yango/.parallax-wt/linkedin-selfservice-bot/S6/assembly-v0404/.parallax/linkedin-selfservice-bot/evidence/events.jsonl`

### Cost signal

The operator observed the Z.ai balance fall from approximately USD 5.6 to USD
4.6 during these calls. Parallax has no exact machine-readable Z.ai balance
adapter, so this is operator-observed evidence rather than a runtime receipt.
It is nevertheless consistent with the documented fact that GLM thinking
consumes output tokens even though Parallax ultimately receives no usable
`message.content`.

Official references:

- Chat Completions and response fields:
  <https://docs.z.ai/api-reference/llm/chat-completion>
- Thinking defaults and `thinking.type=disabled`:
  <https://docs.z.ai/guides/capabilities/thinking-mode>
- Thinking token consumption:
  <https://docs.z.ai/guides/capabilities/thinking>
- JSON mode:
  <https://docs.z.ai/guides/capabilities/struct-output>

## P0 finding — paid reasoning is invisible to the runtime

### Current implementation

`scripts/review-runtime.py:218-227` sends:

```python
body = {
    "model": model,
    "messages": [...],
    "temperature": 0,
    "max_tokens": int(provider.get("review_max_tokens", 12000)),
    "response_format": {"type": "json_object"},
}
```

It does not send `thinking`. For GLM models that default to thinking enabled,
the provider may emit substantial `message.reasoning_content` before producing
the final JSON in `message.content`.

`scripts/review-runtime.py:147-154` reads only
`choices[0].message.content`. An empty string becomes the generic
`empty-provider-response`; `reasoning_content`, `finish_reason`, and `usage`
are discarded.

`scripts/review-runtime.py:235-247` uses one non-streaming `urlopen` read and
collapses URL errors, socket timeout, OS errors, and response JSON decoding
into `provider-timeout-or-network`.

The repository already documents that GLM is a reasoning model and that the
verdict lives in `message.content`, but `tests/t_review_runtime.sh` only mocks a
minimal successful payload. It does not model thinking-only responses, token
termination, usage metadata, or a real read timeout.

### Required behavior

#### P0.1 — explicit thinking policy

Add a provider-level field such as:

```toml
review_thinking = "disabled"
```

Registry schema: enum `disabled | enabled`; default for `review-api` should be
`disabled`, not provider-defined. Emit the provider-specific request body only
when the endpoint supports the field:

```json
"thinking": {"type": "disabled"}
```

The reviewer needs a small structured verdict, not an unbounded hidden
reasoning transcript. If enabled thinking is retained as an opt-in, it must be
explicit in the frozen provider contract and cost reporting.

#### P0.2 — bounded output and timeout defaults

- Direct Z.ai reviewer default: `review_max_tokens = 8192`.
- Direct Z.ai reviewer default timeout: `review_timeout_s = 600`.
- Do not solve this by raising max tokens to 24K-32K or timeout indefinitely.
- Request-level timeout overrides may only narrow or explicitly override the
  frozen provider value; they must be visible in provider-attempt evidence.

The 8192 value is a conservative ceiling, not proof of remaining balance. The
full schema and supplied evidence remain unchanged.

#### P0.3 — retain bounded diagnostic metadata

On every HTTP 200 response, parse and retain only safe metadata:

```json
{
  "finish_reason": "stop|length|sensitive|network_error|...",
  "prompt_tokens": 0,
  "completion_tokens": 0,
  "total_tokens": 0,
  "content_chars": 0,
  "reasoning_chars": 0,
  "request_id": "provider request id if present"
}
```

Never persist `reasoning_content`, the full provider payload, API keys, or
authorization headers. The metadata belongs in the normalized provider
attempt/failure artifact, not in the spec or review ledger.

Required error classes:

- `reasoning-only-response`: reasoning exists, content is empty.
- `output-token-exhausted`: `finish_reason=length` and no valid verdict.
- `provider-sensitive-stop`: provider reports sensitive termination.
- `provider-inference-network-error`: provider response reports network error.
- `empty-provider-response`: both content and reasoning are empty and no more
  precise provider termination explains it.
- `provider-read-timeout`: socket/read deadline elapsed.
- `provider-connect-error`: DNS/connect/TLS failure.
- `malformed-provider-response-json`: HTTP body is not valid provider JSON.

All remain provider failures. None may be converted to PASS or hand-extracted.

#### P0.4 — cost-safe retry policy

- No automatic retry after an HTTP 200 paid response with non-zero completion
  usage unless policy explicitly allows one retry.
- A retry must be recorded with the prior error class, usage metadata, changed
  parameters, and reason.
- Repeating the exact same body after `reasoning-only-response` is prohibited.
- `fallback=false` remains absolute.
- A missing usage object is `unknown`, never zero.

#### P0.5 — optional streaming follow-up, not required for the first fix

Streaming can reduce idle-read ambiguity and expose incremental
`reasoning_content`/`content`, but it complicates transport parsing. If added,
buffer the final content in memory, validate it against the full schema, then
atomically write the same raw verdict. Streaming must not write partial raw
receipts or reasoning text to disk.

The minimum safe release is explicit disabled thinking plus diagnostics and
tests; streaming can follow separately.

## P1 finding — declared done-gates create forbidden cache writes

During the LinkedIn S6 corrective coder run, the worker changed only:

- `src/linkedin_bot/bot.py`
- `src/linkedin_bot/engine.py`
- the allowed worker report

The declared lint/compile/import commands then created:

- `.ruff_cache/**`
- `src/linkedin_bot/__pycache__/**`

The runtime correctly refused the attempt, but this makes an ordinary declared
done-gate incompatible with its own visibility manifest.

Required remediation:

1. Worker dispatch must set `PYTHONDONTWRITEBYTECODE=1` for Python roles.
2. Ruff must run with cache disabled (`ruff --no-cache` or the supported
   environment equivalent).
3. Provider prompts and domain skills must require no generated caches at the
   final guard boundary.
4. Disposable retry worktrees must be the default after a mutation-guard
   failure. A non-disposable dirty attempt is preserved as quarantine evidence;
   it is never silently committed, reset, or used as the next clean base.
5. Do not broadly allow `.ruff_cache/**` or `__pycache__/**` as writable source
   paths. Prevent the writes instead; otherwise mutation evidence becomes noisy
   and role-owned commits may accidentally capture generated files.

## Required tests

Extend `tests/t_review_runtime.sh` or split a focused test file. The harness must
execute these cases, not grep for implementation strings.

### Reviewer request contract

1. Z.ai reviewer body contains `thinking={"type":"disabled"}` by default.
2. Explicit provider opt-in can enable thinking and is frozen in the provider
   contract.
3. JSON mode and full local schema validation remain unchanged.
4. Default max tokens and timeout match the new bounded policy.

### Response classification

5. `reasoning_content` non-empty + content empty ->
   `reasoning-only-response`; no raw receipt.
6. `finish_reason=length` + empty/invalid content ->
   `output-token-exhausted`; no raw receipt.
7. Empty content and reasoning -> `empty-provider-response`.
8. Socket timeout -> `provider-read-timeout`.
9. Connect/DNS/TLS failure -> `provider-connect-error`.
10. Malformed HTTP JSON -> `malformed-provider-response-json`.
11. Valid content plus reasoning -> only content is parsed and schema-validated;
    reasoning is never persisted.
12. Existing raw receipt remains byte-identical after every failure.

### Safe telemetry

13. Attempt evidence records finish reason, bounded usage, character counts,
    timeout, max tokens, and thinking policy.
14. Secret and reasoning-text leak scans remain green.
15. Missing usage is represented as unknown/null, not zero.

### Retry and cost policy

16. A paid reasoning-only response cannot trigger an identical automatic retry.
17. `fallback=false` prevents alternate provider/transport dispatch.
18. A permitted retry records its parameter delta and parent attempt.

### Worker cache guard

19. Python blind-coder done-gate with Ruff + compile/import creates no cache
    paths and is accepted when only allowed files changed.
20. Deliberate unexpected source/control writes still fail the visibility guard.
21. A failed non-disposable attempt cannot be silently reconciled or accepted.

## Live acceptance plan

Unit tests alone are insufficient because the v0.40.6 unit fixture never
exercised a real reasoning response.

Use one deliberately small, cost-capped live smoke before resuming production:

1. A tiny synthetic review with Z.ai, thinking disabled, max tokens 2048,
   timeout 600, expected schema-valid PASS.
2. Record usage and finish reason metadata; confirm no reasoning text or secret
   is persisted.
3. Run exactly one saved production checkpoint sequentially, not three in
   parallel. Recommended first checkpoint: LinkedIn S6 after local arbiter GREEN,
   because its prior Z.ai round has already proven the endpoint/model/schema
   combination can return a valid verdict.
4. If successful, resume Photo S4 against unchanged arbiter tree `32ea1b8`.
5. If successful, resume CreativeHub pre-freeze round 1.
6. Stop immediately after any paid failure; do not repeat identical bodies.

Do not use the production API key in CI. Live smoke evidence is a release
artifact, not a deterministic harness assertion.

## Acceptance criteria for GO

The remediation release is GO only when all are true:

- Full local harness passes with zero failures.
- Plugin validation passes.
- Direct reviewer remains read-only and never launches Aider.
- Thinking policy is explicit and frozen.
- No hidden reasoning text or secret is persisted.
- All response termination modes have deterministic error classes.
- Existing raw receipts remain append-only and failure-safe.
- Python worker done-gates no longer create guard-visible caches.
- One cost-capped Z.ai smoke returns a schema-valid raw verdict.
- At least one saved production checkpoint advances through raw -> ledger ->
  triage without manual extraction.
- Reports distinguish implementation verification from live provider evidence.

## Release recommendation

Ship this as a focused v0.40.7 transport-hardening release. Do not combine it
with new product capability or broad provider refactoring. The release report
must disclose:

- v0.40.6 was fail-closed but not cost-safe under real GLM thinking behavior;
- the exact live failure counts above;
- whether thinking is disabled by default;
- the bounded live-smoke usage and verdict;
- that Photo and CreativeHub remain parked until their existing gates are
  honestly satisfied.

