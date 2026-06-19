#!/usr/bin/env bash
# Cloud-routine setup for the Parallax plugin (Claude Code on the web / "web scheduled task").
# Paste this as the routine Environment's "Setup script". A cloud run is a FRESH CLONE with
# no local tooling, so install the verifier CLIs + project deps here. SECRETS come from the
# routine's Environment variables (never the repo) — see SECURITY.md.
set -uo pipefail
echo "== tdd cloud-setup =="

# 1) Install the verifier CLI(s) you use. These are BEST-EFFORT attempts with the documented
#    package names — adjust to the exact names/versions your account uses if they differ.
command -v codex  >/dev/null 2>&1 || npm i -g @openai/codex      2>/dev/null || true
command -v gemini >/dev/null 2>&1 || npm i -g @google/gemini-cli 2>/dev/null || true
command -v codex  >/dev/null 2>&1 && echo "codex:  $(command -v codex)"  || echo "codex:  NOT installed — set the correct install command for your version"
command -v gemini >/dev/null 2>&1 && echo "gemini: $(command -v gemini)" || echo "gemini: NOT installed — set the correct install command for your version"

# 2) Project build deps so done-gates don't fail spuriously (this is provisioning, per validation.md):
[ -f package.json ] && (npm ci 2>/dev/null || npm install 2>/dev/null) && echo "deps: installed" || echo "deps: no package.json (or install skipped)"
# [ -f prisma/schema.prisma ] && npx prisma generate

# 3) jsonschema is REQUIRED, not optional — the triage gate FAILS CLOSED without it (no validator =>
#    escalate, never green), so an autonomous run with no jsonschema would park every slice. Install
#    it hard and ABORT setup if it still can't be imported, so the operator finds out now, not mid-run.
pip install jsonschema 2>/dev/null || pip install --user jsonschema 2>/dev/null || pip install --break-system-packages jsonschema 2>/dev/null || true
python3 -c "import jsonschema" 2>/dev/null \
  && echo "jsonschema: installed (triage validator present)" \
  || { echo "FATAL: jsonschema not importable — the Parallax triage gate fails closed without it (every slice would escalate). Fix the install before running."; exit 1; }

# 4) Secret presence check — NEVER print values, only whether they're set. Set these in the
#    routine Environment (not the repo). Names match what .parallax/codex.toml references.
for v in OPENAI_API_KEY GEMINI_API_KEY PARALLAX_TG_BOT_TOKEN PARALLAX_TG_CHAT_ID; do
  [ -n "${!v:-}" ] && echo "env: $v set" || echo "env: $v NOT set (set in the routine Environment if the run needs it)"
done

# 5) Reminder for the claude/* push policy of cloud routines:
echo "reminder: set  [git] branch_prefix = \"claude/\"  in .parallax/codex.toml so the run stays in the allowed namespace."
echo "== cloud-setup done =="
