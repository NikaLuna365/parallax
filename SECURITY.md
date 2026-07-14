# Security — secrets never live in this repo

The plugin is designed so that **no secret is ever stored in the repository.** You can put the whole plugin on GitHub safely.

## How secrets are handled
- The config (`.parallax/codex.toml`, template `assets/codex/codex.toml.example`) holds only the **names** of environment variables, never the values:
  - `[notify] token_env = "PARALLAX_TG_BOT_TOKEN"`, `chat_id_env = "PARALLAX_TG_CHAT_ID"`
  - `[fallback] ... key_env = "GEMINI_API_KEY"` (for the `form = "api"` case)
- The actual values live in **environment variables**, supplied at run time:
  - **Local runs:** your shell environment (e.g. a `direnv`/`.envrc` that is **git-ignored**, or your login shell).
  - **Cloud runs (Claude Code web routines):** the routine **Environment → Environment variables** (Anthropic's per-task secret store). The repo is cloned fresh; secrets are injected from the Environment, not from the clone.
- The `codex` / `gemini` CLIs authenticate via their own mechanisms (subscription login, or an API key env var) — same rule: keys in the environment, never committed.
- v0.40 provider registries (`.parallax/providers.toml`) contain only provider names, models, endpoints, and `key_env` names. The runtime discovers `.parallax/.env` first, then legacy `.parallax/zai.env`, then `~/.config/parallax/providers.env`; it reports only `project-local` / `user-local` / process presence. A tracked `*.env` carrier or inline registry secret fails closed.
- Provider budget metadata is not credential metadata. DeepSeek's configured official `GET /user/balance` adapter may yield an exact timestamped balance; Gemini dashboard/project quota, z.ai dashboard usage, Claude subscription `/usage` signals, and Codex local auth/limit banners stay source-labelled and `unknown` for exact personal money. No provider response or billing payload is copied into a spec, prompt, receipt, or frozen contract.
- Live limit commands are read-only supervisor probes. Claude status-line/Desktop usage, Codex `/usage`/`/status` (not `codex doctor`), and Gemini CLI `/stats model` are source-labelled signals, not balances. The supervisor reacts only at safe boundaries and does not promise to preempt a native Claude/Codex host turn without an interception point.
- Claude consumer OAuth credentials must not be forwarded through Aider/API adapters. API keys are passed only to the selected child provider process and are redacted from bounded transport artifacts.
- `openrouter-api` is a separate credential class: it accepts only `OPENROUTER_API_KEY`, never `ZAI_API_KEY`. `/key` is a read-only OpenRouter key-budget source; `/credits` requires an explicitly separate management key; `/models` is a read-only catalog. None of these probes is inference.
- OpenRouter routing (`only`/`order`/`allow_fallbacks`/model fallbacks) and the configured data-retention policy are carried as bounded identity metadata. They do not authorize a hidden provider switch, and an OpenRouter wallet is never described as a direct z.ai balance.
- Persistent routing memory defaults to `~/.config/parallax/provider-state.sqlite` and is chmod 0600. It stores only a one-way credential fingerprint plus normalized status/error metadata; raw keys, provider responses, and the SQLite file never enter Git or evidence artifacts. Operator budgets are estimate-only fields and never populate exact balance.

## What must never be committed
`.gitignore` already excludes the obvious carriers — `.env`, `.envrc`, `*.token`, `*_secret*`, key files. Before committing, double-check:
```bash
git grep -nE 'sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|[0-9]{6,}:[A-Za-z0-9_-]{30,}' || echo "no obvious secrets staged"
```
(matches OpenAI keys, Google API keys, and Telegram bot-token shapes — adjust as needed).

## Run-state and `.parallax/` artifacts
The pipeline commits `.parallax/<slug>/` artifacts (spec, slices, validation, `run-state.json`, queues) to the feature branch by design. **None of these contain secrets** — they reference env-var names only. Keep it that way: never write a token into a spec, a checkpoint, or a notification message.

## Cloud routine = least privilege
- Give the routine Environment only the env vars that run actually needs.
- Keep network access scoped to what the verifier CLIs / git remote require.
- Use `[git] branch_prefix = "claude/"` so the run pushes only within the routine's default `claude/*` policy — you don't have to loosen branch protection.
