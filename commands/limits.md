---
name: limits
description: Show passive provider limit status without making a model request
---

# `/parallax:limits`

Run the read-only provider collector from the repository root:

```bash
python3 scripts/provider-runtime.py limits [provider] [--json] [--watch N]
```

The optional provider can be `z.ai` or its canonical registry name `zai`.
Human output is the default. `--json` emits a snapshot for one provider or a
schema-valid collection for all providers. `--watch N` repeats collection and
marks the last snapshot stale if a later collection fails. Neither mode starts
an inference/model request. Arbitrary `probe_command` entries are not run
unless the registry and `--probe-auth`/`--probe-all` explicitly opt in.

`--recheck` clears the selected provider's persistent routing state before
collection. State is held in a chmod-0600 SQLite file outside the repository;
it can show `exhausted`/`rate_limited` between runs, but it is not quota truth.

The supervisor owns `continue`, `handoff`, `sleep_until_reset`, and `unknown`;
the worker must not query limits or choose a provider. Exact balance remains
null for dashboard-only or local-estimate sources.
