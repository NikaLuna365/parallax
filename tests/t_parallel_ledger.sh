#!/usr/bin/env bash
# v0.23 P0#2 regression — EXECUTES the parallel integration: the committed review ledger (the receipt
# that carries memory, round budget and codex proof) MUST ride into the CAS-promoted commit. v0.22
# re-applied only src/test deltas onto the new tip, dropping .parallax/<slug>/reviews/ entirely.
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$TMP"; git init -q; git config user.email t@t; git config user.name t
mkdir -p src tests .parallax/demo/reviews
echo base>src/a.ts; git add -A; git commit -q -m wavebase; WB=$(git rev-parse HEAD)

# the 2c green commit (in an assembly worktree): reviewed code + tests + ledger receipt
echo impl>src/a.ts; echo tc>tests/a.test.js
echo '{"slug":"demo","slice_id":"S1","rounds_used":1,"findings":[]}'>.parallax/demo/reviews/S1.json
git add -- ':(glob)src/**' ':(glob)tests/**' ':(glob)**/*.test.*' .parallax/demo/reviews/S1.json
git commit -q -m "S1 green (reviewed tree + receipt)"; GREEN=$(git rev-parse HEAD)

# integrate per v0.23: ONE delta WB->GREEN over src+tests+reviews onto a fresh detached tip, then CAS
git switch -q --detach "$WB"
git diff --binary "$WB" "$GREEN" -- ':(glob)src/**' ':(glob)tests/**' ':(glob)**/*.test.*' '.parallax/demo/reviews/' \
  | git apply --3way --index --binary || { echo "FAIL: integration apply failed"; exit 1; }
git commit -q -m "S1 assembled (reviewed tree + receipt)"; INTEG=$(git rev-parse HEAD)

LED=$(git ls-tree -r "$INTEG" --name-only | grep -c 'parallax/demo/reviews/S1.json' || true)
[ "$LED" = 1 ] || { echo "FAIL: ledger receipt NOT carried into the integrated commit (P0#2)"; exit 1; }
git cat-file -p "$INTEG:src/a.ts" | grep -q impl || { echo "FAIL: integrated code != reviewed code"; exit 1; }
echo "t_parallel_ledger OK (ledger receipt survives CAS integration; integrated == reviewed)"
