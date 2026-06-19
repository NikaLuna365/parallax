# Parallax

> **Independent paths. One verified result.**

A spec-driven, blind-coder TDD pipeline (Claude Code plugin). *Code and tests look at one specification from independent vantage points; their divergence reveals the hidden defect — like parallax: two lines of sight on one object expose its true depth.*

A maximally-concrete, **read-only spec** drives two **independent** tracks — a test-writer and a blind coder that never sees the tests — and a single whole-seeing **arbiter** loops with failure analysis until green, then integrates and pushes. An optional, structurally-independent **cross-model verifier** (Codex, with a Gemini fallback) reviews the spec before the blind tracks and each green slice after.

> **What this plugin *is*, honestly.** It is a set of **prompt contracts** — `commands/`, `agents/`, `skills/` — executed by Claude, plus `assets/` (JSON schemas, a config template) and a `tests/` self-test harness. It is **not** a standalone binary. A config option is "implemented" only insofar as a contract branch actually consumes it; see `CHANGELOG.md` for what is wired vs. in progress. The `tests/` harness exists precisely so these contracts don't silently drift.

## Commands
- **`/parallax:spec`** — turn an idea (or a `--from-doc` brief) into a frozen, build-ready spec + slice manifest + validation contract. Stops at a human OK gate (or, autonomously, a machine self-review + cross-model pre-freeze review).
- **`/parallax:run`** — build each slice with a blind test-writer + blind coder, arbitrate to green, integrate, push. Supports `--autonomous`, `--parallel`, `--resume`.
- **`/parallax:auto <brief>`** — the autonomous end-to-end driver: spec → build, no human gates, headless and schedulable.

## The cross-model verifier (opt-in)
Copy `assets/codex/codex.toml.example` to your repo as `.parallax/codex.toml` and set `enabled = true`. The verifier runs a **provider chain** of non-Claude models — a `[primary]` (Codex via the `codex` CLI) and an optional `[fallback]` (e.g. Gemini via the `gemini` CLI). On a primary rate-limit it falls back to the next provider; only if all are exhausted does the run pause. Without this config the pipeline runs exactly as before (Claude-only gates).

Key behaviours, documented in the contracts:
- **Autonomous & parallel** — independent slices build in dependency-DAG waves (`commands/run.md` → *Autonomous & parallel execution*).
- **Limits & resume** — on a usage limit (Claude or Codex) the run checkpoints `.parallax/<slug>/run-state.json` and pauses; an hourly `--resume` continues from the checkpoint (`run.md` → *Limits, checkpointing & resume*).
- **Notifications** — optional Telegram push for the autonomous flow, secrets via env vars (`run.md` → *Notifications*).
- **Review memory & disposition (producer-proof)** — each review is a *fresh* verifier (no anchoring session); findings carry across rounds in **per-slice** committed ledgers (`.parallax/<slug>/reviews/<id>.json`) so fixes are re-checked for regression instead of re-discovered. The verifier emits a review-round (`assets/codex/review-round.schema.json`); `scripts/merge-ledger.py` is the **only** writer of findings (Claude authors none), and `scripts/triage.py` disposes **mechanically**: policy is read **only** from the trusted `.parallax/codex.toml` (never the ledger), and a `fixed` finding counts **only** if the verifier verified it (`verified_by=codex`) against the current diff — so the producer can't certify itself. `low` = advisory; `medium`/`high` block; `safety`/`anti-cheat`/`spec-gap` always block; Claude can only *contest* a blocker (→ escalates), never quietly overrule it. `[review].max_rounds` bounds the loop (`run.md` → *Review memory, rounds & disposition*).

## Configuration
- `.parallax/codex.toml` — the verifier config (provider chain, points, `mode`, retry, notify). Template: `assets/codex/codex.toml.example`. **Secrets (tokens, API keys) live in env vars named by the config — never in the file.**

## Scheduling & running with the laptop off
Three ways to run on a cadence (per Claude Code docs):

| | Cloud (web routine) | Desktop / Cowork task | cron / `/loop` |
|--|--|--|--|
| Runs with the laptop **off** | **Yes** (Anthropic cloud) | No — skips, runs on wake | No |
| Local files | No — **fresh clone** | Yes | Yes |
| Min interval | 1 hour | 1 min | 1 min |

For an **overnight / laptop-off** autonomous run, use a **Claude Code web scheduled task**. Because it's a fresh cloud clone, set it up so the plugin can actually run:

1. **Plugin in the repo** (or installed via the routine setup) so `commands/`/`agents/`/`skills/` are present.
2. **Setup script** = `scripts/cloud-setup.sh` — **best-effort** installs the `codex`/`gemini` CLIs (adjust the package names for your versions if they differ) + project deps, and checks the required secrets are present.
3. **Secrets** in the routine **Environment variables** (codex/gemini keys, `PARALLAX_TG_*`, git push creds) — never in the repo (`SECURITY.md`).
4. **Branch policy:** cloud routines push only to `claude/*` by default. Set `[git] branch_prefix = "claude/"` in `.parallax/codex.toml` (and use a `claude/`-prefixed epic) so the whole run stays in-policy — no need to enable "Allow unrestricted branch pushes".
5. Prompt the routine with `/parallax:auto <brief>` (or `/parallax:run --resume <slug>` for the hourly resume).

Local scheduling (Cowork desktop / cron) works too, but only while the machine is awake.

## Testing
```bash
pip install jsonschema      # optional, for full schema validation
bash tests/run.sh           # the plugin's own regression harness
```
The harness locks the invariants (TOML semantics, schema validity, reference integrity, the git **assembly-not-merge** rule, and the smoke-validation logic). The helpers `tests/verify-codex.sh` and `tests/verify-gemini.sh` confirm the real `codex` / `gemini` CLIs on **your** machine (the one thing the harness can't do remotely).

## Layout
```
.claude-plugin/   plugin + marketplace manifests
commands/         /parallax:spec, /parallax:run, /parallax:auto
agents/           arbiter, test-writer-*, blind-coder-*, codex-judge (dispatched by name)
skills/           parallax-core, role-*, domain-*  (the operating contracts)
assets/           codex/ (verdict + spec-adversary schemas, codex.toml.example), run-state.schema.json
references/        bundled testing-anti-patterns reference
tests/            run.sh + checks + the smoke helpers
```
