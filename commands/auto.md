---
name: auto
description: "Autonomous end-to-end driver of the tdd pipeline. From a written brief, run Phase 1 (spec, autonomous) then Phases 2-5 (build, autonomous + parallel) with no human at the console: the human gates are replaced by the independent cross-model verifier, independent slices build in parallel waves, and anything genuinely ambiguous is parked to a queue for later human review. Headless and schedulable (cron/CI/Cowork). Use only when no principled fork remains to decide. Requires the cross-model verifier configured in .tdd/codex.toml."
argument-hint: "<brief-path>   [feature-slug]   |   --resume <feature-slug>"
---

# /tdd:auto — drive the whole cycle unattended from a brief

Run the full pipeline end-to-end from a written **brief**, with no human gates, for when there are **no principled forks left to decide** — an MVP without big decisions, or a spec already brainstormed to where the remaining choices are mechanical. This is the autonomous union of `/tdd:spec` and `/tdd:run`; it adds no new mechanism, it only removes the human from the console and replaces them with an independent verifier.

## What it does

1. **Spec — autonomously.** Perform Phase 1 per **`/tdd:spec` → Autonomous mode**: the brief (`<brief-path>`) is the source of truth; ambiguities resolve into a **decision-log** in *Resolved assumptions*; the machine self-review and its targeted passes run in full; and the **human OK gate is replaced by the Codex pre-freeze spec review**. A genuine fork the brief doesn't settle means the task wasn't autonomous-ready — stop and report it, never guess a principled decision.

2. **Build — autonomously, in parallel.** Perform Phases 2-5 per **`/tdd:run` → Autonomous & parallel execution**: independent slices build in **parallel waves** (per-slice worktrees over the dependency DAG), each gated by the Claude arbiter **and** the post-green cross-model verifier. Genuine spec-gaps, circuit-breaker trips, and Claude↔Codex divergences **park to the escalation queue** while other independent slices keep going; the run completes every slice it safely can.

3. **Stop — never ship blind.** Nothing reaches `main` without a human: epic → `main` is always a PR with CI and review. Product copy is queued for human wording sign-off. The run ends with a machine-readable report — integrated vs parked slices (with reasons), the escalation queue, the product-copy queue, the decision-log, and the full commit inventory — which is exactly what a human reviews after an unattended run. If `[notify]` is configured, the run's lifecycle (start / limit-pause / resume / complete / needs-human) — or every phase in `verbose` mode — is also pushed to **Telegram** as it goes (see `/tdd:run` → *Notifications*), so you don't have to watch the console.

## Preconditions (refuse rather than run unsafe)

- **The cross-model verifier must be available.** In autonomous mode the verifier *is* the gate that replaces the human, so it is not optional here. If `.tdd/codex.toml` is missing/`enabled=false` or the `codex` CLI is unavailable, honor `on_missing` — default **`refuse`** (do not run autonomously without an independent verifier). `--allow-unverified` overrides but stamps every artifact `UNVERIFIED — human review required` and still refuses to touch `main`.
- **Clean local repo; epic base from `origin/<epic>`.** The preflight provenance check still runs first (fresh `git fetch`, ancestor scan against the **remote** tip, known-deviations registry) — a scheduled run always starts from the current remote tip, never a stale local ref.

## Deferred / routine runs (scheduling)

`/tdd:auto` is **fully headless** — no prompts, a deterministic brief-path in, a machine report out — so any scheduler can fire it; the plugin stays scheduler-agnostic. Wire it however the environment prefers:

- `cron` / CI → `claude -p "/tdd:auto <brief-path>"` at a specific date/time or on a cadence.
- Cowork → a scheduled task that runs the same line (a feature of the environment, not of this plugin).

"Run it at 2am" or "every Monday" is the scheduler's job, not the command's. Every guarantee holds unattended: the base is re-fetched from `origin/<epic>`; anything genuinely ambiguous is parked, not guessed; nothing reaches `main` without a human; deps are provisioned per worktree. **Idempotency:** the same brief writes the same `.tdd/<slug>/`; on a repeat run, continue the unfinished slices or refuse on an already-open run — never duplicate or trample an in-flight cycle.

## Limits & resume (Claude or Codex quota)

A long autonomous run can hit either service's limit — Claude's (which kills the orchestrator) or Codex's (which fails the verifier). It never loses progress: the orchestrator checkpoints `.tdd/<slug>/run-state.json` eagerly and **pauses the whole run** on a sustained limit — but only **after the verifier exhausts its provider chain** (a Codex limit first falls back to e.g. Gemini, no pause; the run pauses only when every provider is limited). A quota error is transient infra — never a fault, never `concerns`, never shipped. Mechanics live in `/tdd:run` → *Limits, checkpointing & resume*.

- **Resume:** `/tdd:auto --resume <slug>` (or `/tdd:run --resume <slug>`) reads the checkpoint, re-fetches `origin/<epic>` (provenance still runs), and continues exactly where it paused — skipping `integrated` slices, finishing any owed verification, idempotently. Worst case lost on an interruption is one slice's current iteration; never the whole run.
- **Hourly retry:** drive it the same headless way as any schedule — `cron`/CI or a Cowork scheduled task firing the resume each hour (interval in `[retry]` of `.tdd/codex.toml`; prefer the limit error's `retry_after` if it carried one). The schedule **self-terminates** when the checkpoint reads `complete`.
- A resume that is **still limited fails fast** — one cheap probe, re-checkpoint `paused-on-limit`, exit — so it never burns quota idling.

## What it is NOT for

Anything with an open **principled** decision — a real safety, UX, or business fork. If you would need to *ask* a human during the spec, this is the wrong command: use interactive `/tdd:spec`. Autonomy decides the *mechanical* questions for you; it must never decide the hard ones, and it is built to stop and ask (via the queue) rather than pretend it can.
