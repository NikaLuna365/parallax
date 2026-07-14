# Parallax v0.40.7 release report

## Scope

v0.40.7 is a focused remediation of the v0.40.6 live Z.ai reviewer failures.
The implementation lives in `scripts/review-runtime.py` and the shared
provider runtime.
It does not add a new provider or change the reviewer role: Z.ai/OpenRouter
reviewers remain direct read-only transports, while Aider remains available for
worker roles that are explicitly allowed to edit.

## Verification

- Full local harness: **191 passed, 0 failed**.
- Focused reviewer and worker-runtime tests: passed.
- Python syntax and `git diff --check`: passed.
- One real, cost-capped Z.ai smoke: schema-valid `pass`.
- Smoke parameters: `glm-5.2`, `thinking=disabled`, `max_tokens=2048`,
  timeout `600s`.
- Smoke metadata: `finish_reason=stop`, prompt `11451`, completion `16`,
  total `11467`, content `32` chars, reasoning `0` chars.
- Smoke raw receipt SHA-256:
  `24ae4f4b07f7ec91f883ae292805b48c71882722930b466eafbf21aa0213c0fc`.

The raw smoke receipt contained only the schema-valid verdict and no secret or
reasoning text. The API key remained in the local ignored `.parallax/.env` and
was not committed or printed.

## Limits of evidence

The smoke proves the direct transport and receipt path with the current Z.ai
key. It is not a substitute for a saved production checkpoint advancing
through arbiter, raw receipt, merge-ledger, triage, and freeze. Photo Bot and
CreativeHub therefore remain governed by their existing fail-closed gates.

## Remediated findings

- GLM thinking is explicitly disabled by default; output and timeout are
  bounded and effective values are recorded.
- Provider termination modes have deterministic error classes and bounded
  diagnostics; reasoning text and full provider payloads are not persisted.
- Existing raw receipts are preserved on every provider failure.
- Python/Ruff done-gates no longer create guard-visible caches; the visibility
  guard runs again after the gate.
