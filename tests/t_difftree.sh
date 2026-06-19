#!/usr/bin/env bash
# v0.22 P0#1 regression — EXECUTES the git mechanic + triage.
# The review --current-diff must be the `git write-tree` of the STAGED assembled tree, NOT
# `HEAD^{tree}`. The assembled slice is staged-but-uncommitted, so HEAD has not moved; HEAD^{tree}
# is therefore invariant to a content change, and a codex-verified `fixed` recorded against it
# re-matches a tree that has since changed => FALSE GREEN. write-tree moves with the staged content,
# so the stale fix is correctly re-blocked.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$REPO/assets/codex/codex.toml.example"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cd "$TMP"; git init -q; git config user.email t@t; git config user.name t
mkdir -p src; echo base > src/x.ts; git add -A; git commit -q -m base
# stage assembled content A (NOT committed) — this is the tree the verifier reviews
echo vA > src/x.ts; git add -A; HEAD_A=$(git rev-parse "HEAD^{tree}"); WT_A=$(git write-tree)
# coder changes something; re-assemble -> stage content B (HEAD still has not moved)
echo vB > src/x.ts; git add -A; HEAD_B=$(git rev-parse "HEAD^{tree}"); WT_B=$(git write-tree)

[ "$HEAD_A" = "$HEAD_B" ] || { echo "FAIL: HEAD^{tree} changed without a commit (test premise wrong)"; exit 1; }
[ "$WT_A" != "$WT_B" ]   || { echo "FAIL: write-tree did not move with staged content (test premise wrong)"; exit 1; }

led(){ printf '{"slug":"d","slice_id":"S1","rounds_used":1,"findings":[{"id":"S1-N1","fingerprint":"f","severity":"high","kind":"safety","spec_ref":"s#a","claim":"c","evidence":"e","status":"fixed","verified_by":"codex","last_verified_diff":"%s"}]}' "$1"; }
dec(){ echo "$1" | python3 "$REPO/scripts/triage.py" - --policy "$TOML" --current-diff "$2" --no-schema-check 2>/dev/null; }

# OLD method (HEAD^{tree}): fix recorded vs HEAD, checked vs HEAD -> tokens equal though content changed -> GREEN = the bug.
OLD=$(dec "$(led "$HEAD_A")" "$HEAD_B")
echo "$OLD" | grep -q '"decision": "green"' \
  && echo "  reproduced: HEAD^{tree} method FALSE-GREENs a since-changed tree" \
  || { echo "FAIL: HEAD^{tree} method did not reproduce the false-green: $OLD"; exit 1; }

# FIX (write-tree): fix recorded vs WT_A, checked vs WT_B -> tokens differ -> BLOCK (stale fix caught).
NEW=$(dec "$(led "$WT_A")" "$WT_B")
echo "$NEW" | grep -q '"decision": "block"' \
  && echo "  fixed: write-tree method BLOCKS the stale fix on the changed tree" \
  || { echo "FAIL: write-tree method failed to block the stale fix: $NEW"; exit 1; }

echo "t_difftree OK"
