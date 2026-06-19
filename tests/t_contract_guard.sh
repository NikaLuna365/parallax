#!/usr/bin/env bash
# v0.27 P0 — EXECUTES the worktree-contract guard. The verifier reads the WORKTREE contract, but contract-hash
# hashes HEAD; without a guard an uncommitted spec edit (or an untracked contract file) lets the receipt claim
# the committed spec while the verifier reviewed a different one. The guard is:
#   git diff --quiet HEAD -- <contract paths>   (catches staged+unstaged drift)   AND
#   ls-files --others -- <contract paths> empty (catches an untracked contract file)
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# (1) committed-vs-worktree drift: an uncommitted spec edit is missed by the src/tests guard, caught by the contract guard
A="$TMP/a"; git init -q "$A"; git -C "$A" config user.email t@t; git -C "$A" config user.name t
mkdir -p "$A/src" "$A/.parallax/demo"
echo code>"$A/src/a.ts"
printf 'STRICT SPEC A\n' > "$A/.parallax/demo/spec.md"; echo S1>"$A/.parallax/demo/slices.md"
echo 'full: npm test'>"$A/.parallax/demo/validation.md"; echo '{"slug":"demo","slices":["S1"]}'>"$A/.parallax/demo/slices.lock"
git -C "$A" add -A; git -C "$A" commit -q -m "freeze contract A"
C=( .parallax/demo/spec.md .parallax/demo/slices.md .parallax/demo/validation.md .parallax/demo/slices.lock )
git -C "$A" diff --quiet HEAD -- "${C[@]}" || { echo "FAIL: contract guard tripped on a clean contract"; exit 1; }
printf 'WEAK SPEC B SEEN BY VERIFIER\n' > "$A/.parallax/demo/spec.md"     # verifier reads the worktree; not committed
git -C "$A" diff --quiet -- ':(glob)src/**' ':(glob)tests/**' || { echo "FAIL: src/tests guard unexpectedly tripped"; exit 1; }
if git -C "$A" diff --quiet HEAD -- "${C[@]}"; then echo "FAIL: contract guard missed an uncommitted spec edit"; exit 1; fi
echo "  uncommitted spec edit: src/tests guard misses it, contract guard (diff HEAD) catches it"

# (2) untracked contract file: diff HEAD can't see it, the ls-files --others guard catches it
B="$TMP/b"; git init -q "$B"; git -C "$B" config user.email t@t; git -C "$B" config user.name t
mkdir -p "$B/.parallax/demo"
echo S1>"$B/.parallax/demo/slices.md"; printf 'spec\n'>"$B/.parallax/demo/spec.md"; echo 'full: t'>"$B/.parallax/demo/validation.md"
git -C "$B" add -A; git -C "$B" commit -q -m "no slices.lock committed"
echo '{"slug":"demo","slices":["S1"]}' > "$B/.parallax/demo/slices.lock"    # present ONLY untracked
git -C "$B" diff --quiet HEAD -- "${C[@]}" || { echo "FAIL: diff HEAD unexpectedly fired on an untracked-only file"; exit 1; }
[ -n "$(git -C "$B" ls-files --others --exclude-standard -- "${C[@]}")" ] || { echo "FAIL: untracked contract file not detected"; exit 1; }
echo "  untracked contract file: ls-files --others catches what diff HEAD cannot"
echo "t_contract_guard OK"
