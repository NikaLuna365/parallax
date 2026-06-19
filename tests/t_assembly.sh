#!/usr/bin/env bash
# EXECUTES the parallel integration end-to-end. Locks:
#   P0 #1 — per-slice DIFF integration preserves EVERY slice of a wave (mirror loses them).
#   P0 #2 — it all works under a non-default branch prefix (e.g. claude/ for cloud routines).
# Usage: t_assembly.sh [branch_prefix]   (default feature/)
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PFX="${1:-feature/}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=':(glob)src/**'; TST=':(glob)tests/**'
WB=""

build(){ # $1=dir -> cd's the PARENT shell into a fresh repo with two INDEPENDENT slices; sets global WB
  git init -q -b main "$1" >/dev/null; cd "$1" || exit 1
  mkdir src tests; echo base>src/base.txt; echo base>tests/base.test.txt
  git add -A; git commit -q -m base; git switch -q -c "${PFX}demo"
  WB=$(git rev-parse HEAD)
  local n
  for n in 1 2; do
    git switch -q -c "${PFX}demo-S$n-code" "${PFX}demo"; git rm -q -r tests >/dev/null; git commit -q -m bf; printf 's%s\n' "$n">src/S$n.txt;        git add -A; git commit -q -m c
    git switch -q -c "${PFX}demo-S$n-test" "${PFX}demo"; git rm -q -r src   >/dev/null; git commit -q -m bf; printf 's%s\n' "$n">tests/S$n.test.txt; git add -A; git commit -q -m t
  done
  git switch -q "${PFX}demo"
}
has(){ git ls-files | grep -qx "$1"; }

# 1) DIFF integration (the fix) — both slices of the wave survive
build "$T/d"
intg(){ git diff --binary "$WB" "${PFX}demo-S$1-code" -- "$SRC" | git apply --3way --index --binary 2>/dev/null
        git diff --binary "$WB" "${PFX}demo-S$1-test" -- "$TST" | git apply --3way --index --binary 2>/dev/null
        git commit -q -m "intg S$1"; }
intg 1; intg 2
{ has src/S1.txt && has src/S2.txt && has tests/S1.test.txt && has tests/S2.test.txt; } \
  || { echo "FAIL: per-slice diff integration lost a slice (prefix=$PFX)"; exit 1; }

# 2) the OLD mirror approach MUST lose a prior slice (documents why we don't mirror)
build "$T/m"
mir(){ git rm -q -r --ignore-unmatch -- "$SRC" "$TST" >/dev/null
       git checkout "${PFX}demo-S$1-code" -- "$SRC"; git checkout "${PFX}demo-S$1-test" -- "$TST"
       git add -A; git commit -q -m "mirror S$1"; }
mir 1; mir 2
has src/S1.txt && { echo "FAIL: mirror unexpectedly preserved S1 — the data-loss this fix prevents was not reproduced"; exit 1; }

echo "OK (prefix=$PFX)"
