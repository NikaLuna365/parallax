#!/usr/bin/env bash
# v0.25 P0#1 — EXECUTES the gate->push window. Pushing a pinned immutable OID sends the VERIFIED commit even
# after the feature ref has moved to an unverified tip; pushing the SYMBOLIC ref instead re-resolves at push
# time and would send the moved tip into the epic (the TOCTOU). run.md Step 4 pins VERIFIED_OID and pushes it.
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$TMP/epic.git"
git init -q "$TMP/wc"; cd "$TMP/wc"; git config user.email t@t; git config user.name t
git remote add origin "$TMP/epic.git"
echo A>f; git add -A; git commit -q -m A; git branch -M feature/demo
A=$(git rev-parse HEAD)                                   # the gate-verified commit
echo B>f; git commit -q -am B; B=$(git rev-parse HEAD)    # ref moves to an UNVERIFIED tip after the gate

git push -q origin "feature/demo:refs/heads/epic_via_ref"   # BUGGY: re-resolves the moving ref -> B
git push -q origin "$A:refs/heads/epic_via_oid"             # FIX:   pinned verified OID -> A
RVR=$(git -C "$TMP/epic.git" rev-parse epic_via_ref)
RVO=$(git -C "$TMP/epic.git" rev-parse epic_via_oid)
[ "$RVR" = "$B" ] || { echo "FAIL: premise — pushing the symbolic ref did not send the moved tip"; exit 1; }
[ "$RVO" = "$A" ] || { echo "FAIL: pushing the pinned OID did not send the verified commit (got $RVO want $A)"; exit 1; }
echo "t_immutable_oid OK (pinned OID -> verified commit A; the symbolic ref would have sent the moved tip B)"
