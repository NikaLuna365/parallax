#!/usr/bin/env bash
# Canonical hash of the FROZEN normative contract for a feature at a git ref: the artifacts the work is
# verified AGAINST — .parallax/<slug>/{spec.md, slices.md, validation.md, slices.lock}. code-tree-hash.sh
# deliberately excludes ALL of .parallax/ (to ignore mutable ledger/run-state churn), which also left these
# frozen spec artifacts unbound: an implementation could be verified against a strict spec, then the spec or
# validation contract rewritten after review, and still promoted (v0.26 P0). This hash binds them. ONE
# definition, used by merge-ledger.py (records contract_hash, frozen per run) and epic-gate.py (recomputes
# from the pinned feature commit and requires the match). A missing file hashes a stable <<MISSING>> marker,
# so deleting a required artifact also moves the hash.
#
# v0.37.5 5.2 (Gap-1 remediation): review-policy.frozen.json is part of the frozen contract set.
# Without this, the pinned budget could be laundered by DELETING the pin and re-pinning from an
# edited codex.toml (the pin's own overwrite refusal only guards an existing file). Anchoring the
# pin here means a delete+re-pin moves contract_hash, every ledger's stamped contract_hash
# mismatches, and the epic-gate HOLDs — the pin is legitimately written exactly once, at freeze,
# and never changes (budget widening lives in amendments/BA-*.json, never in the pin).
#
# Usage: contract-hash.sh <ref> <slug> [repo]
set -uo pipefail
REF="${1:?usage: contract-hash.sh <ref> <slug> [repo]}"
SLUG="${2:?usage: contract-hash.sh <ref> <slug> [repo]}"
REPO="${3:-.}"
{ for f in spec.md slices.md validation.md slices.lock review-policy.frozen.json; do
    printf '=== %s ===\n' "$f"
    git -C "$REPO" show "$REF:.parallax/$SLUG/$f" 2>/dev/null || printf '<<MISSING>>\n'
  done
} | git -C "$REPO" hash-object --stdin
