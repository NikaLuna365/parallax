#!/usr/bin/env bash
# v0.39 §5.2 (D1/D2) + §5.4 + §5.6 — EXECUTES the monorepo silent-failure guards against REAL git
# repos. These fix the *cause* of the v0.38.1 hand-driving. Locks (see-it-fail-first):
#   D1  blindfold-guard.py --assert-pathspec-match: a zero-match test pathspec (src/-prefixed
#       workspace) FAILS CLOSED (a `git rm` would silently no-op); the right pathspec matches; a
#       genuinely test-less slice passes with --allow-no-tests;
#   5.4 blindfold-guard.py --base-ref: in scope mode a NEW-since-base impl file absent from
#       protected_impl_paths, reachable via a broad dependency_allow_globs, FAILS CLOSED on the test
#       side (guard:196 hole) — while WITHOUT --base-ref it is masked (proves the fix bites);
#   D2  push-guard.sh: ref-current refuses a LAGGING branch ref (detached-HEAD hazard); ancestor
#       refuses a non-fast-forward push; committed refuses a track that didn't commit / wrong branch.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; BG="$PLUGIN/scripts/blindfold-guard.py"; PG="$PLUGIN/scripts/push-guard.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
python3 -c 'import jsonschema' 2>/dev/null || { echo "SKIP"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

# ---------- D1: zero-match blindfold pathspec fails closed ----------
M="$T/m"; git init -q -b main "$M"; git -C "$M" config user.email t@t; git -C "$M" config user.name t
mkdir -p "$M/packages/api/src"; echo x > "$M/packages/api/src/a.test.ts"; echo y > "$M/packages/api/src/impl.ts"
git -C "$M" add -A; git -C "$M" commit -qm base; MB=$(git -C "$M" rev-parse HEAD)
python3 "$BG" --assert-pathspec-match --repo "$M" --pathspec ':(glob)tests/**' >/tmp/parallax_d1a 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "D1: zero-match (tests/** on a src-prefixed tree) not failed closed (rc=$RC)"
grep -qF 'zero-match' /tmp/parallax_d1a || fail "D1: wrong reason: $(cat /tmp/parallax_d1a)"
python3 "$BG" --assert-pathspec-match --repo "$M" --pathspec ':(glob)**/*.test.*' >/dev/null || fail "D1: the RIGHT pathspec did not match"
python3 "$BG" --assert-pathspec-match --repo "$M" --pathspec ':(glob)tests/**' --allow-no-tests >/dev/null || fail "D1: --allow-no-tests did not permit a genuine zero-match"

# ---------- 5.4: guard:196 — a new impl file under a broad dep-glob, absent from protected ----------
git -C "$M" switch -q -c feature/m-S1-test
mkdir -p "$M/packages/shared/src"; echo 'new' > "$M/packages/shared/src/leak.ts"
git -C "$M" add -A; git -C "$M" commit -qm "new shared impl (slice's own, must be caught)"
cat > "$T/scope.json" <<J
{"schema_version":"parallax-blindfold-scope-v1","slug":"m","slice_id":"S1","protected_impl_paths":[],"protected_test_paths":[],"dependency_allow_globs":["packages/shared/src/**"]}
J
# WITHOUT --base-ref: the broad dep-glob masks the new impl -> guard reports clean (the OLD hole)
python3 "$BG" --worktree "$M" --side test --slug m --scope-manifest "$T/scope.json" --impl-glob '**/*.ts' >/tmp/parallax_54a 2>&1
grep -qF '"verdict": "clean"' /tmp/parallax_54a || fail "5.4 setup: expected the un-hardened path to report clean (dep-glob mask)"
# WITH --base-ref: the new-since-base impl absent from protected_impl fails closed
python3 "$BG" --worktree "$M" --side test --slug m --scope-manifest "$T/scope.json" --impl-glob '**/*.ts' --base-ref "$MB" >/tmp/parallax_54b 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "5.4: new impl file absent from protected_impl NOT failed closed under --base-ref (rc=$RC)"
grep -qF 'leak.ts' /tmp/parallax_54b || fail "5.4: the new impl leak not named: $(cat /tmp/parallax_54b)"
grep -qF 'new-implementation-source-visible-to-test-writer-absent-from-protected' /tmp/parallax_54b || fail "5.4: wrong why"

# ---------- D2: push-guard ----------
R="$T/r"; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)
git -C "$R" switch -q -c feature/demo; echo b >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm work
TIP=$(git -C "$R" rev-parse feature/demo); git -C "$R" switch -q main
bash "$PG" ref-current "$R" feature/demo "$TIP" >/dev/null || fail "D2: ref-current rejected a CURRENT ref"
bash "$PG" ref-current "$R" feature/demo "$BASE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "D2: a LAGGING branch ref not refused (rc=$RC)"
bash "$PG" ancestor "$R" "$BASE" "$TIP" >/dev/null || fail "D2: ancestor rejected a fast-forward"
bash "$PG" ancestor "$R" "$TIP" "$BASE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "D2: a non-ancestor (non-ff) push not refused (rc=$RC)"
# committed: a worktree that did NOT advance past base
bash "$PG" committed "$R" "$R" "$(git -C "$R" rev-parse HEAD)" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "D2/§5.6: a non-committing track not refused (rc=$RC)"
# committed to the WRONG branch
WT="$T/wt"; git -C "$R" worktree add -q "$WT" feature/demo >/dev/null 2>&1
bash "$PG" committed "$R" "$WT" "$BASE" wrong-branch >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "D2/§5.6: committed-to-wrong-branch not refused (rc=$RC)"
bash "$PG" committed "$R" "$WT" "$BASE" feature/demo >/dev/null || fail "D2/§5.6: a legit commit on the right branch was refused"

echo "t_monorepo_guards OK"
