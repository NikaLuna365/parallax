#!/usr/bin/env bash
# Parallax v0.31 P2 — generation-restart git mechanic (DESIGN_v0.31_safe_completion.md §11/§12).
#
# After a human decision is APPLIED by scripts/resolution.py (which bumps feature-state to generation N+1,
# mints a new run_id, writes the batch receipt and resolves the queue items), this script performs the
# APPEND-ONLY git restart that fully invalidates the old certification and rebuilds the feature on a FRESH
# epic, with NO old implementation/tests on the active paths:
#
#   * the active code tree becomes a fresh `<epic>` tip — the old blind-coder implementation is gone from the
#     working tree, so a new blind run starts from clean code; the old code stays reachable ONLY through git
#     ancestry, never shown to the new blind workers (DESIGN §11);
#   * the old normative contract, run-state and review ledgers are archived under
#     .parallax/<slug>/history/generation-<N>/ — auditable, but off the active paths the epic gate reads, so a
#     stale-generation green ledger can never certify the new contract;
#   * the new generation N+1 contract (spec/slices/validation/slices.lock), the gen-N+1 feature-state, the
#     batch receipt and any prior cross-generation resolutions are installed at the canonical paths; NO active
#     run-state is written — the next /parallax:run creates a fresh one (all slices pending);
#   * a single restart commit is created with TWO parents — the OLD feature tip (so the feature branch stays
#     APPEND-ONLY: the old tip remains an ancestor and the ref only ever fast-forwards, never rewriting
#     history) and the FRESH epic tip (so the new epic base is in the new generation's provenance);
#   * the feature ref advances by an ATOMIC compare-and-swap (git update-ref <ref> <restart> <old-tip>):
#     exactly one racing resolver wins; a loser observes the moved ref and refuses to clobber it.
#
# Crash-safety / idempotency: nothing mutates the feature ref until the final CAS, so a crash BEFORE the CAS
# leaves the feature untouched (a re-run rebuilds and advances). A crash AFTER the CAS is recognized on a
# re-run (the tip already carries generation N+1 with this batch in the chain) and the script no-ops. The CAS
# makes the whole advance all-or-nothing.
#
# Honest scope: this is the mechanical, executable half (locked by tests/t_resolution_generation.sh +
# tests/t_resolution_race.sh). Taking the cross-process resolution LEASE so two resolvers don't even start
# together is the run-lock mechanism reused at the /parallax:resolve (P4) level; the feature-ref CAS here is
# the last-line atomic guarantee that, even if two do run, only one generation N+1 ever lands.
#
# Usage:
#   generation-restart.sh --repo DIR --slug SLUG --epic EPIC_REF --feature FEATURE_REF \
#     --expect-tip OID --to-generation N --batch-id RB-xxxx \
#     --contract-dir DIR --feature-state FILE --receipt FILE [--queue FILE] [--remote NAME]
# Exit: 0 ok/no-op, 2 bad input, 9 race-lost / CAS-failed (the feature ref is left untouched).
set -uo pipefail

die(){ echo "generation-restart: $1" >&2; exit "${2:-2}"; }

REPO="."; REMOTE=""; QUEUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --slug) SLUG="$2"; shift 2;;
    --epic) EPIC="$2"; shift 2;;
    --feature) FEATURE="$2"; shift 2;;
    --expect-tip) EXPECT="$2"; shift 2;;
    --to-generation) TO="$2"; shift 2;;
    --batch-id) BATCH="$2"; shift 2;;
    --contract-dir) CONTRACT_DIR="$2"; shift 2;;
    --feature-state) FS_FILE="$2"; shift 2;;
    --receipt) RECEIPT="$2"; shift 2;;
    --queue) QUEUE="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    *) die "unknown argument: $1";;
  esac
done

: "${SLUG:?--slug required}" "${EPIC:?--epic required}" "${FEATURE:?--feature required}"
: "${EXPECT:?--expect-tip required}" "${TO:?--to-generation required}" "${BATCH:?--batch-id required}"
: "${CONTRACT_DIR:?--contract-dir required}" "${FS_FILE:?--feature-state required}" "${RECEIPT:?--receipt required}"
case "$TO" in ''|*[!0-9]*) die "--to-generation must be an integer (got '$TO')";; esac
FROM=$((TO - 1)); [ "$FROM" -ge 1 ] || die "--to-generation must be >= 2 (got $TO)"
for f in spec.md slices.md validation.md slices.lock; do
  [ -f "$CONTRACT_DIR/$f" ] || die "contract-dir is missing $f"
done
[ -f "$FS_FILE" ]  || die "feature-state file not found: $FS_FILE"
[ -f "$RECEIPT" ]  || die "receipt file not found: $RECEIPT"

G(){ git -C "$REPO" "$@"; }
FEATURE_REF="refs/heads/$FEATURE"
G rev-parse --verify -q "$FEATURE_REF" >/dev/null || die "no feature branch '$FEATURE'"
CUR=$(G rev-parse "$FEATURE_REF")

# Resolve the FRESH epic tip — never a stale local ref (DESIGN §12 step 2).
if [ -n "$REMOTE" ]; then
  G fetch -q "$REMOTE" "$EPIC" || die "git fetch $REMOTE $EPIC failed" 9
  EPIC_OID=$(G rev-parse FETCH_HEAD)
else
  EPIC_OID=$(G rev-parse --verify -q "$EPIC") || die "no epic ref '$EPIC'"
fi

# ---- idempotency / race guard (decided BEFORE anything is built or moved) ----
fs_gen(){ G show "$1:.parallax/$SLUG/feature-state.json" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('generation',0))" 2>/dev/null || echo 0; }
fs_has_batch(){ G show "$1:.parallax/$SLUG/feature-state.json" 2>/dev/null \
  | python3 -c "import json,sys; print('1' if sys.argv[1] in json.load(sys.stdin).get('resolution_chain',[]) else '0')" "$BATCH" 2>/dev/null || echo 0; }

if [ "$CUR" != "$EXPECT" ]; then
  # The feature ref already moved off the tip this resolver observed. Two cases:
  #   (a) WE already landed this exact restart (a crash AFTER the CAS): the tip carries generation >= TO with
  #       this batch in the chain -> a safe idempotent no-op.
  #   (b) someone else advanced it: refuse, never clobber (no force).
  if [ "$(fs_gen "$CUR")" -ge "$TO" ] && [ "$(fs_has_batch "$CUR")" = "1" ]; then
    echo "{\"decision\":\"noop\",\"reason\":\"feature already at generation>=$TO with $BATCH\",\"feature\":\"$FEATURE\",\"feature_tip\":\"$CUR\"}"
    exit 0
  fi
  die "race-lost: feature ref moved $EXPECT -> $CUR (another resolver or run advanced it); refusing to clobber" 9
fi

# Don't update a ref that is the checked-out HEAD of $REPO (it would leave that worktree stale) — detach
# first, mirroring run.md's parallel topology where $ROOT sits detached while the branch is a CAS-advanced ref.
if [ "$(G symbolic-ref -q --short HEAD || true)" = "$FEATURE" ]; then G switch -q --detach || die "could not detach HEAD before advancing $FEATURE" 9; fi

WTBASE=$(mktemp -d); WT="$WTBASE/restart"
cleanup(){ G worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$WTBASE"; }
trap cleanup EXIT
G worktree add -q --detach "$WT" "$EPIC_OID" || die "could not create the restart worktree at $EPIC_OID" 9

FEAT_DIR="$WT/.parallax/$SLUG"
rm -rf "$FEAT_DIR"                                   # the epic should carry no .parallax/<slug>; start clean
HIST="$FEAT_DIR/history/generation-$FROM"
mkdir -p "$HIST/contract" "$HIST/reviews" "$FEAT_DIR/resolutions"

# Archive the OLD generation's normative contract + run-state + reviews (auditable history, off active paths).
for f in spec.md slices.md validation.md slices.lock; do
  G show "$EXPECT:.parallax/$SLUG/$f" > "$HIST/contract/$f" 2>/dev/null || true
done
G show "$EXPECT:.parallax/$SLUG/run-state.json" > "$HIST/run-state.json" 2>/dev/null || true
for P in $(G ls-tree -r --name-only "$EXPECT" -- ".parallax/$SLUG/reviews" 2>/dev/null); do
  G show "$EXPECT:$P" > "$HIST/reviews/$(basename "$P")" 2>/dev/null || true
done
printf '{"from_generation":%d,"to_generation":%d,"batch_id":"%s","old_feature_tip":"%s","fresh_epic_oid":"%s"}\n' \
  "$FROM" "$TO" "$BATCH" "$EXPECT" "$EPIC_OID" > "$HIST/generation-manifest.json"

# Carry forward CROSS-generation artifacts from the old tip (prior batch receipts + the queue), then overlay
# this batch's new ones. (feature-state, the queue and resolutions/ span generations; contract/run-state/
# reviews are per-generation and were just archived above.)
for P in $(G ls-tree -r --name-only "$EXPECT" -- ".parallax/$SLUG/resolutions" 2>/dev/null); do
  G show "$EXPECT:$P" > "$FEAT_DIR/resolutions/$(basename "$P")" 2>/dev/null || true
done
if [ -n "$QUEUE" ]; then
  cp "$QUEUE" "$FEAT_DIR/resolution-queue.json"
else
  G show "$EXPECT:.parallax/$SLUG/resolution-queue.json" > "$FEAT_DIR/resolution-queue.json" 2>/dev/null || true
fi

# Install the NEW generation N+1 canonical contract + feature-state + this batch receipt.
for f in spec.md slices.md validation.md slices.lock; do cp "$CONTRACT_DIR/$f" "$FEAT_DIR/$f"; done
cp "$FS_FILE" "$FEAT_DIR/feature-state.json"
cp "$RECEIPT" "$FEAT_DIR/resolutions/$BATCH.json"
# (deliberately no active .parallax/<slug>/run-state.json — /parallax:run writes a fresh one for the new
#  generation; the old run-state lives only under history/, so the gate can never read a stale-gen receipt.)

# Build the append-only restart commit: parent 1 = old feature tip (fast-forward/append-only),
# parent 2 = fresh epic tip (provenance). The tree is the fresh epic's code + the new .parallax/<slug>.
git -C "$WT" add -A
TREE=$(git -C "$WT" write-tree) || die "git write-tree failed in the restart worktree" 9
RESTART=$(git -C "$WT" commit-tree "$TREE" -p "$EXPECT" -p "$EPIC_OID" \
  -m "parallax: restart $SLUG g$FROM->g$TO (batch $BATCH) — fresh $EPIC base; old generation archived to history; old code dropped from the active tree") \
  || die "git commit-tree failed" 9

# Atomic compare-and-swap: advance ONLY if the feature ref is still the tip we built on. A racing resolver
# that already advanced it makes this fail; we refuse rather than clobber (the restart is a fast-forward of
# the old tip, so this never rewrites history).
if ! G update-ref "$FEATURE_REF" "$RESTART" "$EXPECT"; then
  die "CAS failed: $FEATURE moved from $EXPECT under us; not advancing" 9
fi

# Fast-forward publish: the old tip is an ancestor of the restart, so origin only ever fast-forwards here.
if [ -n "$REMOTE" ]; then
  G push "$REMOTE" "$RESTART:$FEATURE_REF" || die "publish to $REMOTE rejected (origin/$FEATURE advanced); fetch + retry the restart" 9
fi

echo "{\"decision\":\"restarted\",\"slug\":\"$SLUG\",\"from_generation\":$FROM,\"to_generation\":$TO,\"batch_id\":\"$BATCH\",\"feature\":\"$FEATURE\",\"restart_oid\":\"$RESTART\",\"old_tip\":\"$EXPECT\",\"epic_oid\":\"$EPIC_OID\"}"
