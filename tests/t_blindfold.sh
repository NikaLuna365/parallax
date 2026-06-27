#!/usr/bin/env bash
# v0.37 P0.1 — EXECUTES scripts/blindfold-guard.py against REAL git worktrees. Locks the mechanical
# blindness wall: leaked implementation source / compiled dist in the test worktree is rejected, a
# clean test worktree (tests + an allowed public fixture) passes, a leaked test file in the coder
# worktree is rejected, and a clean coder worktree passes.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; G="$PLUGIN/scripts/blindfold-guard.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk(){ git init -q "$1"; git -C "$1" config user.email t@t; git -C "$1" config user.name t; }
ci(){ git -C "$1" add -A; git -C "$1" commit -q -m x; }
fail(){ echo "FAIL: $1"; exit 1; }

# 1) test worktree with leaked implementation source + compiled dist -> reject (exit 2)
mk "$T/tw"; mkdir -p "$T/tw/src" "$T/tw/dist" "$T/tw/tests"
echo 'def add(a,b): return a+b' > "$T/tw/src/calc.py"
echo 'module.exports={}'        > "$T/tw/dist/bundle.js"
echo 'def test_add(): assert True' > "$T/tw/tests/test_calc.py"; ci "$T/tw"
python3 "$G" --worktree "$T/tw" --side test --slug demo >/dev/null; [ $? -eq 2 ] || fail "leaked src/dist not rejected on test side"

# 2) clean test worktree (tests + an explicitly allowed public fixture) -> pass (exit 0)
mk "$T/cl"; mkdir -p "$T/cl/tests/fixtures"
echo 'def test_x(): assert True' > "$T/cl/tests/test_x.py"
echo '{"baseline":42}'           > "$T/cl/tests/fixtures/baseline.json"; ci "$T/cl"
python3 "$G" --worktree "$T/cl" --side test --slug demo >/dev/null; [ $? -eq 0 ] || fail "clean test worktree rejected"

# 3) coder worktree with a leaked test file -> reject (exit 2)
mk "$T/cw"; mkdir -p "$T/cw/src" "$T/cw/tests"
echo 'def add(a,b): return a+b' > "$T/cw/src/calc.py"
echo 'def test_add(): assert add(1,2)==3' > "$T/cw/tests/test_calc.py"; ci "$T/cw"
python3 "$G" --worktree "$T/cw" --side code --slug demo >/dev/null; [ $? -eq 2 ] || fail "leaked test not rejected on code side"

# 4) clean coder worktree (impl only) -> pass (exit 0)
git -C "$T/cw" rm -q tests/test_calc.py >/dev/null; ci "$T/cw"
python3 "$G" --worktree "$T/cw" --side code --slug demo >/dev/null; [ $? -eq 0 ] || fail "clean coder worktree rejected"

echo "t_blindfold OK"
