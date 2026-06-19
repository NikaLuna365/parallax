#!/usr/bin/env bash
# EXECUTES the documented lock (v0.19 cloud fix). Locks P0 #1:
#   - local create-if-absent with a real object,
#   - cross-clone mutual exclusion over TWO FRESH, SAME-HEAD clones (the real cloud case the
#     v0.17 lock missed): a UNIQUE lock commit (run_id baked in) + `git push --force-with-lease=<ref>:`
#     yields exactly ONE winner,
#   - plus a GUARD proving the test discriminates: the OLD same-value approach lets BOTH win.
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
Z=0000000000000000000000000000000000000000
REF=refs/heads/feature/lock/demo

# echo a UNIQUE commit oid over HEAD's tree (so two same-HEAD clones produce DIFFERENT lock objects)
mklock(){ git commit-tree "$(git rev-parse HEAD^{tree})" -m "parallax-lock run_id=$1 exp=2030"; }

# 1) local create-if-absent with a real object (NOT a run_id string)
git init -q -b main "$T/r" >/dev/null
( cd "$T/r" && git commit -q --allow-empty -m x
  git update-ref "$REF" "$(mklock RUNL)" "$Z" 2>/dev/null || { echo "FAIL: documented local lock command errored"; exit 1; }
  git update-ref "$REF" "$(mklock RUNL2)" "$Z" 2>/dev/null && { echo "FAIL: a second local create succeeded — no mutual exclusion"; exit 1; }
  true ) || exit 1

# bare origin + two FRESH clones that SHARE THE SAME HEAD (the real cloud scenario)
git init -q --bare -b main "$T/origin" >/dev/null
git init -q -b main "$T/seed" >/dev/null
( cd "$T/seed" && git commit -q --allow-empty -m x && git remote add o "$T/origin" && git push -q o main )
git clone -q "$T/origin" "$T/c1" >/dev/null 2>&1; git clone -q "$T/origin" "$T/c2" >/dev/null 2>&1
[ "$(git -C "$T/c1" rev-parse HEAD)" = "$(git -C "$T/c2" rev-parse HEAD)" ] \
  || { echo "FAIL: clones don't share HEAD — the test would be vacuous"; exit 1; }

# 2a) GUARD — OLD approach: point the ref at the SHARED HEAD, plain push -> BOTH win (the bug we fixed)
( cd "$T/c1" && git update-ref "$REF" "$(git rev-parse HEAD)" && git push -q origin "$REF" 2>/dev/null ) && b1=win || b1=lose
( cd "$T/c2" && git update-ref "$REF" "$(git rev-parse HEAD)" && git push -q origin "$REF" 2>/dev/null ) && b2=win || b2=lose
{ [ "$b1" = win ] && [ "$b2" = win ]; } \
  || { echo "FAIL: guard expected OLD same-value push to let BOTH win, got $b1/$b2"; exit 1; }
git -C "$T/c1" push -q origin --delete "$REF" 2>/dev/null || true   # reset origin lock for 2b

# 2b) THE FIX — unique lock commit + force-with-lease=<ref>: (expect absent) over the SAME HEAD -> one winner
( cd "$T/c1" && git update-ref "$REF" "$(mklock RUNA)"; git push -q origin --force-with-lease="$REF": "$REF" 2>/dev/null ) && r1=win || r1=lose
( cd "$T/c2" && git update-ref "$REF" "$(mklock RUNB)"; git push -q origin --force-with-lease="$REF": "$REF" 2>/dev/null ) && r2=win || r2=lose
{ { [ "$r1" = win ] && [ "$r2" = lose ]; } || { [ "$r1" = lose ] && [ "$r2" = win ]; }; } \
  || { echo "FAIL: unique-commit + force-with-lease did not yield exactly one winner ($r1/$r2)"; exit 1; }

# 3) EXPIRED-lock steal must be lease-PINNED to the observed oid — a bare --force lets BOTH stealers win.
git -C "$T/c1" push -q origin --delete "$REF" 2>/dev/null || true
( cd "$T/c1" && git update-ref "$REF" "$(mklock EXPIRED)"; git push -q origin --force-with-lease="$REF": "$REF" )   # seed an expired lock
OLD=$(git -C "$T/c1" ls-remote origin "$REF" | awk '{print $1}')
( cd "$T/c1" && git fetch -q origin && git update-ref "$REF" "$(mklock STEALA)"; git push -q origin --force-with-lease="$REF:$OLD" "$REF" 2>/dev/null ) && s1=win || s1=lose
( cd "$T/c2" && git fetch -q origin && git update-ref "$REF" "$(mklock STEALB)"; git push -q origin --force-with-lease="$REF:$OLD" "$REF" 2>/dev/null ) && s2=win || s2=lose
{ { [ "$s1" = win ] && [ "$s2" = lose ]; } || { [ "$s1" = lose ] && [ "$s2" = win ]; }; } \
  || { echo "FAIL: expired-lock steal not mutually exclusive — both --force-with-lease=<ref>:<oid> stealers got $s1/$s2"; exit 1; }

# 4) Fenced release: a release whose lease points at the WRONG oid must NOT delete the lock.
WRONG=1111111111111111111111111111111111111111
( cd "$T/c2" && git push -q origin --force-with-lease="$REF:$WRONG" ":$REF" 2>/dev/null ) && rel=deleted || rel=fenced
[ "$rel" = fenced ] || { echo "FAIL: a wrong-oid lease deleted the lock (fence broken)"; exit 1; }
[ -n "$(git -C "$T/c1" ls-remote origin "$REF")" ] || { echo "FAIL: lock vanished after a fenced (should-fail) release"; exit 1; }

echo "OK"
