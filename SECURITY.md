# Security — secrets never live in this repo

The plugin is designed so that **no secret is ever stored in the repository.** You can put the whole plugin on GitHub safely.

## How secrets are handled
- The config (`.tdd/codex.toml`, template `assets/codex/codex.toml.example`) holds only the **names** of environment variables, never the values:
  - `[notify] token_env = "TDD_TG_BOT_TOKEN"`, `chat_id_env = "TDD_TG_CHAT_ID"`
  - `[fallback] ... key_env = "GEMINI_API_KEY"` (for the `form = "api"` case)
- The actual values live in **environment variables**, supplied at run time:
  - **Local runs:** your shell environment (e.g. a `direnv`/`.envrc` that is **git-ignored**, or your login shell).
  - **Cloud runs (Claude Code web routines):** the routine **Environment → Environment variables** (Anthropic's per-task secret store). The repo is cloned fresh; secrets are injected from the Environment, not from the clone.
- The `codex` / `gemini` CLIs authenticate via their own mechanisms (subscription login, or an API key env var) — same rule: keys in the environment, never committed.

## What must never be committed
`.gitignore` already excludes the obvious carriers — `.env`, `.envrc`, `*.token`, `*_secret*`, key files. Before committing, double-check:
```bash
git grep -nE 'sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|[0-9]{6,}:[A-Za-z0-9_-]{30,}' || echo "no obvious secrets staged"
```
(matches OpenAI keys, Google API keys, and Telegram bot-token shapes — adjust as needed).

## Run-state and `.tdd/` artifacts
The pipeline commits `.tdd/<slug>/` artifacts (spec, slices, validation, `run-state.json`, queues) to the feature branch by design. **None of these contain secrets** — they reference env-var names only. Keep it that way: never write a token into a spec, a checkpoint, or a notification message.

## Cloud routine = least privilege
- Give the routine Environment only the env vars that run actually needs.
- Keep network access scoped to what the verifier CLIs / git remote require.
- Use `[git] branch_prefix = "claude/"` so the run pushes only within the routine's default `claude/*` policy — you don't have to loosen branch protection.
