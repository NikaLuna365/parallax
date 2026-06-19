#!/usr/bin/env bash
# Canonical "code tree" hash of a git ref: a content hash of EVERY tracked file EXCEPT .parallax/
# (review metadata that legitimately changes after the code is frozen). This is the ONE definition,
# used by BOTH run.md (records it into run-state.verified_tree when a run completes) and
# scripts/epic-gate.py (recomputes it from the promoted feature commit and requires equality) — so the
# feature-level receipt is bound to the ACTUAL committed tree: any code/test/config change after
# verification moves this hash, while a .parallax/ ledger or run-state write does not.
#
# Usage: code-tree-hash.sh <ref> [repo]
set -uo pipefail
REF="${1:?usage: code-tree-hash.sh <ref> [repo]}"
REPO="${2:-.}"
# ls-tree -r lists "<mode> blob <sha>\t<path>"; drop the .parallax/ paths (review metadata), hash the rest.
# `|| true` so an (degenerate) all-.parallax tree still hashes to the empty-input object rather than erroring.
{ git -C "$REPO" ls-tree -r "$REF" | grep -v $'\t\.parallax/' || true; } | git -C "$REPO" hash-object --stdin
