---
name: parallax-workflow
description: Use the Parallax spec-driven blind-coder TDD workflow in this repository, including provider limits, fallback, fail-closed gates, and independent verification.
---

# Parallax workflow

Use this skill when the user asks to build, test, review, or resume work through
the Parallax pipeline in this repository.

Before choosing an implementation path, read the applicable contract in
`commands/spec.md`, `commands/run.md`, or `commands/auto.md`, plus
`references/runtime-governance.md` when the run can pause, fall back, or adopt.
Treat those files as the workflow contract; do not invent a shortcut that skips
the blindfold, receipt, review, or finalize gates.

For provider-aware work, use `scripts/provider-runtime.py` and the configured
`.parallax/providers.toml`. Keep keys in ignored env files only. Use
`limits --json` for passive observations and explicit probe flags only when a
read-only probe is required. Never present an unknown balance as zero or as a
confirmed quota.

Keep implementation, test-writing, arbitration, and independent verification
separate. If a required artifact, provider, or host capability is unavailable,
park with the documented reason instead of claiming a green result.
