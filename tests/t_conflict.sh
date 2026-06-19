#!/usr/bin/env bash
# EXECUTES the transactional, assembly-worktree integration. Locks P1 #2 + #3:
#   two non-independent slices (both edit the same line) — S1 applies in the slice's ASSEMBLY
#   worktree, S2 CONFLICTS, the rollback (git reset --hard) leaves the assembly clean, and the
#   shared feature/<slug> ref is NEVER moved by the failed wave (no half-patched tree on feature).
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=':(glob)src/**'
git init -q -b main "$T/r" >/dev/null; cd "$T/r"; ROOT=$(pwd)
mkdir src tests; printf 'L1\nL2\nL3\n' >src/shared.txt; echo base>tests/b.txt; git add -A; git commit -q -m base
git switch -q -c feature/demo; WB=$(git rev-parse HEAD)
for n in 1 2; do   # both slices change the SAME line -> not independent
  git switch -q -c "feature/demo-S$n-code" feature/demo; git rm -q -r tests >/dev/null; git commit -q -m bf
  printf 'L1\nS%s-change\nL3\n' "$n" >src/shared.txt; git add -A; git commit -q -m c
done
git switch -q feature/demo
FEAT_BEFORE=$(git rev-parse feature/demo)

git worktree add -q --detach "$ROOT/.awt" feature/demo
rc=0
( cd "$ROOT/.awt" && git switch -q --detach "$(git -C "$ROOT" rev-parse feature/demo)"
  git diff --binary "$WB" feature/demo-S1-code -- "$SRC" | git apply --3way --index --binary || exit 7
  git commit -q -m S1
  if git diff --binary "$WB" feature/demo-S2-code -- "$SRC" | git apply --3way --index --binary; then
     echo "UNEXPECTED: conflicting S2 applied cleanly"; exit 8; fi   # must conflict
  git reset -q --hard                                                # transactional rollback
  [ "$(git status --porcelain | wc -l)" -eq 0 ] || { echo "assembly NOT clean after rollback"; exit 9; }
) || rc=$?
git worktree remove --force "$ROOT/.awt" 2>/dev/null || true

[ "$rc" -eq 0 ] || { echo "FAIL: transactional rollback path (rc=$rc)"; exit 1; }
[ "$FEAT_BEFORE" = "$(git rev-parse feature/demo)" ] \
  || { echo "FAIL: feature/demo MOVED despite a failed wave — integration was not transactional"; exit 1; }
echo "OK"
