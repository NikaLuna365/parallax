#!/usr/bin/env bash
# EXECUTES binary-file integration. Locks P1 #4:
#   `git diff --binary | git apply --binary` integrates a modified binary file, AND
#   a PLAIN (non --binary) diff of the same change FAILS to apply — proving --binary is load-bearing.
set -uo pipefail
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=':(glob)src/**'
git init -q -b main "$T/r" >/dev/null; cd "$T/r"
mkdir src; printf '\x00\x01\x02base\xff' >src/blob.bin; git add -A; git commit -q -m base
git switch -q -c feature/demo; WB=$(git rev-parse HEAD)
git switch -q -c feature/demo-S1-code feature/demo
printf '\x00\x01\x02CHANGED\xff\xfe\xfd' >src/blob.bin; git add -A; git commit -q -m 'binary change'; TIP=$(git rev-parse HEAD)

# a plain (non --binary) diff MUST fail to apply a binary change (else --binary buys nothing)
git switch -q feature/demo
if git diff "$WB" "$TIP" -- "$SRC" | git apply --3way --index 2>/dev/null; then
  echo "FAIL: a plain diff applied a binary change — test is vacuous"; exit 1; fi
git reset -q --hard

# the documented --binary path MUST apply it, and the bytes must match the slice exactly
git diff --binary "$WB" "$TIP" -- "$SRC" | git apply --3way --index --binary 2>/tmp/parallax_bin_err \
  || { echo "FAIL: --binary diff did not apply: $(cat /tmp/parallax_bin_err)"; exit 1; }
cmp -s <(git show "$TIP:src/blob.bin") src/blob.bin \
  || { echo "FAIL: integrated binary bytes differ from the slice"; exit 1; }
echo "OK"
