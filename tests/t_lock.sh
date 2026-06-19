#!/usr/bin/env bash
# EXECUTES the documented lock. Locks P1 #3:
#   - the local command works (ref -> a real object / HEAD, NOT a run_id string),
#   - and gives real mutual exclusion across two FRESH CLONES via push (the cloud case).
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
Z=0000000000000000000000000000000000000000
REF=refs/heads/feature/lock/demo

# 1) local create-if-absent with a REAL object (exactly as documented)
git init -q -b main "$T/r" >/dev/null
( cd "$T/r" && git commit -q --allow-empty -m x
  H=$(git rev-parse HEAD)
  git update-ref "$REF" "$H" "$Z" 2>/dev/null || { echo "FAIL: documented local lock command errored"; exit 1; }
  git update-ref "$REF" "$H" "$Z" 2>/dev/null && { echo "FAIL: a second create succeeded — no mutual exclusion"; exit 1; }
  true ) || exit 1

# 2) cross-clone: two fresh clones of a bare origin race to PUSH the lock ref -> exactly one wins
git init -q --bare -b main "$T/origin" >/dev/null   # -b main so clones get a valid HEAD
git init -q -b main "$T/seed" >/dev/null
( cd "$T/seed" && git commit -q --allow-empty -m x && git remote add o "$T/origin" && git push -q o main )
git clone -q "$T/origin" "$T/c1" >/dev/null 2>&1; git clone -q "$T/origin" "$T/c2" >/dev/null 2>&1
# each clone points the lock at a DISTINCT commit, so the loser's create is a real conflict (not a no-op same-value push)
( cd "$T/c1" && git commit -q --allow-empty -m c1 && git update-ref "$REF" "$(git rev-parse HEAD)" "$Z" && git push -q origin "$REF" 2>/dev/null ) && r1=win || r1=lose
( cd "$T/c2" && git commit -q --allow-empty -m c2 && git update-ref "$REF" "$(git rev-parse HEAD)" "$Z" && git push -q origin "$REF" 2>/dev/null ) && r2=win || r2=lose
{ [ "$r1" = win ] && [ "$r2" = lose ]; } || { echo "FAIL: cross-clone lock race did not yield exactly one winner ($r1/$r2)"; exit 1; }

echo "OK"
