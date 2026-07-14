# z.ai limits research appendix (v0.40.1)

Checked 2026-07-14 against the official z.ai documentation:

- [API introduction](https://docs.z.ai/api-reference/introduction) documents
  Bearer API-key authentication, the general API endpoint, and a separate
  Coding Plan endpoint.
- [HTTP API introduction](https://docs.z.ai/guides/develop/http/introduction)
  documents `Authorization: Bearer ZAI_API_KEY` and distinguishes the general
  endpoint from `https://api.z.ai/api/coding/paas/v4`.
- [Official FAQ](https://docs.z.ai/help/faq) directs users to the web billing
  and rate-limit pages. It does not document a machine-readable balance or
  quota endpoint for this runtime to call.
- [Official error reference](https://docs.z.ai/api-reference/api-code) documents
  authentication failures and account-balance exhaustion as API error signals;
  those signals may be recorded from a worker response, but they are not an
  exact balance.
- [Subscription terms](https://docs.z.ai/legal-agreement/subscription-terms)
  state that Coding Plan quota is restricted to supported tools and is not a
  general-purpose API entitlement.

Implementation conclusion:

- `zai-api` is the primary v0.40.1 credential class and uses the documented
  general API base URL when a worker is configured.
- No official machine-readable billing/balance endpoint was proven here, so
  the collector uses `source_class=official-dashboard` only as a dashboard
  limitation label and always emits `budget.remaining=null` and
  `budget.exact=false`.
- `zai-coding-subscription` remains a separate optional credential class. The
  runtime does not forward it through Aider or an arbitrary SDK.
- Undocumented endpoints are not enabled by default. An explicitly opted-in
  adapter would still be `source_class=unknown` and could not become an
  automatic exact-balance or spend-gate source.
