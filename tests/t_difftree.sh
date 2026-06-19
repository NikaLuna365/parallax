#!/usr/bin/env bash
# v0.23 P0#1 + P1#5 regression — EXECUTES the git mechanic of the 2c review->commit step.
#  (1) the review DIFF is a content hash of EXACTLY the reviewed code+tests (git ls-files -s | hash-object):
#      it moves when reviewed code changes, HEAD^{tree} does NOT (the tree is staged, not committed),
#      and it is STABLE against .parallax/ churn (so a ledger write never perturbs the verified diff);
#  (2) the reviewed-scope guard (git diff --quiet -- src tests) IGNORES a modified tracked ledger (P1#5)
#      but ls-files --others still detects an untracked file in the reviewed scope (P0#1 guard => escalate);
#  (3) the green commit uses `git add -- src tests ledger` (NOT git add -A), so an out-of-scope untracked
#      file is NEVER swept into the promoted commit (P0#1).
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$TMP"; git init -q; git config user.email t@t; git config user.name t
mkdir -p src tests .parallax/demo/reviews
echo base>src/x.ts; git add -A; git commit -q -m base

hash_reviewed(){ git ls-files -s -- ':(glob)src/**' ':(glob)tests/**' | git hash-object --stdin; }

# (1) reviewed-content hash moves with code; HEAD^{tree} does not (staged, not committed)
echo vA>src/x.ts; git add -- src tests; HEAD_A=$(git rev-parse "HEAD^{tree}"); HA=$(hash_reviewed)
echo vB>src/x.ts; git add -- src tests; HEAD_B=$(git rev-parse "HEAD^{tree}"); HB=$(hash_reviewed)
[ "$HEAD_A" = "$HEAD_B" ] || { echo "FAIL: HEAD^{tree} moved without a commit"; exit 1; }
[ "$HA" != "$HB" ]        || { echo "FAIL: reviewed-content hash did not move with the code"; exit 1; }
echo "  reviewed-content hash moves with code; HEAD^{tree} does not"

# .parallax/ churn must NOT perturb the reviewed hash, and must NOT trip the scoped guard (P1#5)
echo '{"r":1}'>.parallax/demo/reviews/S1.json; git add .parallax; H_led=$(hash_reviewed)
[ "$HB" = "$H_led" ] || { echo "FAIL: ledger churn changed the reviewed hash"; exit 1; }
git commit -q -m "green: code + ledger receipt"
echo '{"r":2}'>.parallax/demo/reviews/S1.json                                   # next review modifies the tracked ledger
git diff --quiet -- ':(glob)src/**' ':(glob)tests/**' || { echo "FAIL: scoped guard tripped on a ledger-only change (P1#5)"; exit 1; }
echo "  scoped guard ignores a tracked-ledger change (P1#5)"
git checkout -q -- .parallax                                                    # clean slate

# (2) untracked file IN the reviewed scope is detected by the guard (P0#1 => escalate)
echo junk>src/untracked_in_scope.ts
[ -n "$(git ls-files --others --exclude-standard -- ':(glob)src/**' ':(glob)tests/**')" ] || { echo "FAIL: untracked-in-scope not detected"; exit 1; }
rm src/untracked_in_scope.ts
echo "  guard detects an untracked file in the reviewed scope (P0#1 -> escalate)"

# (3) out-of-scope untracked artifact: committing index + receipt-only excludes it; git add -A would not
echo real>src/x.ts; git add -- src/x.ts          # assembly staged the reviewed code into the index
echo junk>stray_root_artifact.txt                 # an out-of-scope untracked artifact appears
git add -- .parallax/demo/reviews/S1.json         # 2c stages ONLY the receipt (NOT git add -A)
git commit -q -m "green (index + receipt)"
git ls-tree -r HEAD --name-only | grep -q stray_root_artifact && { echo "FAIL: committed an out-of-scope untracked file"; exit 1; }
echo "  committing the index + receipt (no git add -A) excluded the out-of-scope untracked artifact (P0#1)"
echo "t_difftree OK"
