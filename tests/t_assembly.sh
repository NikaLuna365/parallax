#!/usr/bin/env bash
# P1 lock: slice integration must be ASSEMBLY (globbed checkout), never a merge of
# the blindfold track branches. This reproduces both: merging destroys the originals
# (the bug), assembly preserves them (the fix). Exit 0 only if both hold.
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

build(){ # $1 = dir; builds repo with blindfold code/testb branches + payloads, leaves cwd on feature
  git init -q -b main "$1" && cd "$1" || exit 1
  mkdir src tests; echo impl > src/app.txt; echo test > tests/app.test.txt
  git add -A; git commit -q -m base; git switch -q -c feature
  git branch code feature; git branch testb feature
  git switch -q code;  git rm -q -r tests >/dev/null; git commit -q -m b1; echo i2 > src/new.txt;       git add -A; git commit -q -m p1
  git switch -q testb; git rm -q -r src   >/dev/null; git commit -q -m b2; echo t2 > tests/new.test.txt; git add -A; git commit -q -m p2
  git switch -q feature
}

# 1) blindfold MERGE must DESTROY the originals (documents why we never merge track branches)
( build "$T/m"; git merge -q --no-edit code >/dev/null 2>&1; git merge -q --no-edit testb >/dev/null 2>&1
  [ ! -f src/app.txt ] && [ ! -f tests/app.test.txt ] ) \
  || { echo "FAIL: blindfold-merge did not show the expected data-loss"; exit 1; }

# 2) ASSEMBLY must PRESERVE the originals AND add the payload
( build "$T/a"
  git rm -q -r --ignore-unmatch -- ':(glob)src/**' ':(glob)tests/**' >/dev/null
  git checkout code  -- ':(glob)src/**'
  git checkout testb -- ':(glob)tests/**'
  [ -f src/app.txt ] && [ -f tests/app.test.txt ] && [ -f src/new.txt ] && [ -f tests/new.test.txt ] ) \
  || { echo "FAIL: assembly lost files"; exit 1; }

echo "OK"
