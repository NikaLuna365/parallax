#!/usr/bin/env bash
# v0.31 P2 — EXECUTES scripts/generation-restart.sh end-to-end with the REAL scripts/resolution.py writer.
# Proves the append-only generation restart (DESIGN §11/§12/§18):
#   * the active tree becomes a FRESH epic with NO old blind-coder code (the old impl is reachable only via
#     ancestry, never on the active path a new blind run would read);
#   * the old contract / run-state / review ledgers are archived under history/generation-<N>/;
#   * the new gen-N+1 contract + feature-state + receipt are installed; no active run-state survives;
#   * the feature advances APPEND-ONLY (the old tip is an ancestor; the publish is a fast-forward, the script
#     never rewrites history) and the FRESH epic tip is in the new generation's provenance;
#   * a re-run is idempotent (a crash AFTER the CAS no-ops, the ref does not move);
#   * a stale expected-tip (a crash/lost view BEFORE the CAS) refuses and leaves the feature untouched.
# Exit: 0 all behaved, 2 SKIP (no jsonschema — resolution.py is the real writer), 1 a case wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
RES="$PLUGIN/scripts/resolution.py"; GR="$PLUGIN/scripts/generation-restart.sh"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail(){ echo "FAIL: $*"; exit 1; }
SLUG=demo
H64="$(printf 'a%.0s' $(seq 1 64))"      # old contract hash
N64="$(printf 'b%.0s' $(seq 1 64))"      # new contract hash

# --- a bare epic remote ---
git init -q --bare -b epic "$TMP/epic.git"
git init -q "$TMP/seed"; ( cd "$TMP/seed"; git config user.email t@t; git config user.name t
  mkdir src; echo 'export const base = 1' > src/base.ts
  git add -A; git commit -q -m "epic base v1"; git branch -M epic
  git remote add origin "$TMP/epic.git"; git push -q origin epic )

# --- the feature repo, forked from the epic base, with a PARKED generation-1 run ---
git clone -q "$TMP/epic.git" "$TMP/feat"; cd "$TMP/feat"; git config user.email t@t; git config user.name t
git switch -q -c "feature/$SLUG" origin/epic
mkdir -p "src" ".parallax/$SLUG/reviews"
echo 'export const oldImpl = "GEN1 leftover"' > src/old_impl.ts          # gen-1 blind code: must NOT survive
printf 'gen1 spec\n'       > ".parallax/$SLUG/spec.md"
printf 'gen1 slices\nS1\n' > ".parallax/$SLUG/slices.md"
printf 'gen1 validation\n' > ".parallax/$SLUG/validation.md"
printf '{"slug":"demo","slices":["S1"]}\n' > ".parallax/$SLUG/slices.lock"
printf '{"slug":"demo","slice_id":"S1","rounds_used":1,"findings":[]}\n' > ".parallax/$SLUG/reviews/S1.json"
python3 "$RES" init-feature ".parallax/$SLUG/feature-state.json" --slug "$SLUG" --feature-id F1 \
  --run-id RUN1 --base-oid "$(git rev-parse HEAD)" --tip-oid "$(git rev-parse HEAD)" --contract-hash "$H64" >/dev/null
python3 "$RES" transition ".parallax/$SLUG/feature-state.json" --slug "$SLUG" --to needs-resolution >/dev/null
cat > "$TMP/item.json" <<JSON
{"id":"R-S1-0001","status":"open","stage":"build","kind":"spec-gap","slice_id":"S1",
 "source_contract_hash":"$H64","source_run_id":"RUN1","spec_refs":["B/retries"],
 "question":"retries default?","options":[{"id":"A","rule":"0","consequence":"x"},{"id":"B","rule":"3","consequence":"y"}],
 "blocked_slices":["S1"],"source_receipts":["reviews/S1.json#N1"]}
JSON
python3 "$RES" add-item ".parallax/$SLUG/resolution-queue.json" --slug "$SLUG" --item-file "$TMP/item.json" >/dev/null
python3 - <<PY
import json
json.dump({"run_id":"RUN1","slug":"demo","epic":"epic","base_tip":"$(git rev-parse HEAD)","status":"needs-resolution",
  "resolution_queue":".parallax/demo/resolution-queue.json","contract_generation":1,"feature_id":"F1",
  "slices":[{"id":"S1","status":"parked","parked_reason":"spec-gap"}],"updated_at":"t"},
  open(".parallax/demo/run-state.json","w"))
PY
git add -A; git commit -q -m "gen1 parked (contract + needs-resolution run-state + reviews + open queue)"
git push -q origin "feature/$SLUG"                 # origin now holds feature/demo at the parked tip
EXPECT=$(git rev-parse "feature/$SLUG")

# --- the human decision: resolution.py APPLIES it (gen-2 feature-state + receipt in the working tree) ---
python3 "$RES" transition ".parallax/$SLUG/feature-state.json" --slug "$SLUG" --to resolving >/dev/null
TOK=$(python3 "$RES" mint-token --slug "$SLUG" --from-gen 1 --batch-id RB-0001 --old-hash "$H64" --new-hash "$N64" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
echo '[{"item_id":"R-S1-0001","decision":"choose-option","option_id":"B","rule":"3"}]' > "$TMP/dec.json"
python3 "$RES" apply ".parallax/$SLUG/feature-state.json" --queue ".parallax/$SLUG/resolution-queue.json" \
  --resolutions-dir ".parallax/$SLUG/resolutions" --slug "$SLUG" --batch-id RB-0001 --source-run-id RUN1 \
  --new-run-id RUN2 --old-hash "$H64" --new-hash "$N64" --token "$TOK" --human-text "use 3" --decisions "$TMP/dec.json" >/dev/null

# --- the epic advances after the fork, so the restart rebases onto a genuinely FRESH tip ---
( cd "$TMP/seed"; echo 'export const base = 2 // moved' >> src/base.ts; git commit -q -am "epic base v2"; git push -q origin epic )
EPIC_FRESH=$( cd "$TMP/seed" && git rev-parse HEAD )

# --- the NEW (generation-2) contract the human/pre-freeze produced ---
mkdir "$TMP/newc"
printf 'gen2 spec: retries defaults to 3\n' > "$TMP/newc/spec.md"
printf 'gen2 slices\nS1\n'                  > "$TMP/newc/slices.md"
printf 'gen2 validation\n'                  > "$TMP/newc/validation.md"
printf '{"slug":"demo","slices":["S1"]}\n'  > "$TMP/newc/slices.lock"

# ---- run the restart ----
RJSON=$(bash "$GR" --repo "$TMP/feat" --slug "$SLUG" --epic epic --feature "feature/$SLUG" \
  --expect-tip "$EXPECT" --to-generation 2 --batch-id RB-0001 --contract-dir "$TMP/newc" \
  --feature-state "$TMP/feat/.parallax/$SLUG/feature-state.json" \
  --receipt "$TMP/feat/.parallax/$SLUG/resolutions/RB-0001.json" --remote origin) \
  || fail "restart exited non-zero: $RJSON"
RESTART=$(echo "$RJSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['restart_oid'])")

cd "$TMP/feat"
# (1) append-only: the old tip is an ancestor of the restart
git merge-base --is-ancestor "$EXPECT" "$RESTART"     || fail "feature is not append-only (old tip is not an ancestor of the restart)"
# (2) the fresh epic tip is in the restart provenance
git merge-base --is-ancestor "$EPIC_FRESH" "$RESTART" || fail "fresh epic tip is not in the restart provenance"
# (3) the active tree is the FRESH epic code; the gen-1 implementation is GONE from the active path
git cat-file -e "$RESTART:src/base.ts" 2>/dev/null    || fail "fresh epic code (src/base.ts) missing from the restart active tree"
git show "$RESTART:src/base.ts" | grep -q "base = 2"  || fail "active src/base.ts is not the FRESH epic version"
if git cat-file -e "$RESTART:src/old_impl.ts" 2>/dev/null; then fail "gen-1 implementation (src/old_impl.ts) leaked into the restart active tree"; fi
git cat-file -e "$EXPECT:src/old_impl.ts" 2>/dev/null  || fail "precondition broken: old code should still exist in ancestry"
# (4) the old contract / run-state / reviews are archived under history/generation-1/
git cat-file -e "$RESTART:.parallax/$SLUG/history/generation-1/contract/spec.md" 2>/dev/null || fail "old contract not archived to history"
git cat-file -e "$RESTART:.parallax/$SLUG/history/generation-1/run-state.json"   2>/dev/null || fail "old run-state not archived to history"
git cat-file -e "$RESTART:.parallax/$SLUG/history/generation-1/reviews/S1.json"  2>/dev/null || fail "old review ledger not archived to history"
git show "$RESTART:.parallax/$SLUG/history/generation-1/contract/spec.md" | grep -q "gen1 spec" || fail "archived spec is not the gen-1 contract"
# (5) the new gen-2 contract is on the ACTIVE path; NO active run-state survives (a fresh run will create it)
git show "$RESTART:.parallax/$SLUG/spec.md" | grep -q "retries defaults to 3" || fail "gen-2 contract not installed at the active path"
if git cat-file -e "$RESTART:.parallax/$SLUG/run-state.json" 2>/dev/null; then fail "a stale active run-state.json survived the restart (must live only under history/)"; fi
# (6) feature-state at the tip is generation 2 with the batch in the chain; the receipt is present
git show "$RESTART:.parallax/$SLUG/feature-state.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['generation']==2 and d['resolution_chain']==['RB-0001'], d" \
  || fail "feature-state at the restart is not generation 2 with RB-0001 in the chain"
git cat-file -e "$RESTART:.parallax/$SLUG/resolutions/RB-0001.json" 2>/dev/null || fail "resolution receipt missing at the restart tip"
# (7) the publish was a fast-forward (no history rewrite): origin/feature advanced to the restart, old tip still an ancestor
ORIGIN_FEAT=$(git -C "$TMP/epic.git" rev-parse "refs/heads/feature/$SLUG" 2>/dev/null) || fail "origin feature ref missing after publish"
[ "$ORIGIN_FEAT" = "$RESTART" ] || fail "origin/feature was not advanced to the restart (got $ORIGIN_FEAT)"
git merge-base --is-ancestor "$EXPECT" "$ORIGIN_FEAT" || fail "origin advance was not a fast-forward (history was rewritten!)"
grep -qE 'push[^|&]*(--force|-f )' "$GR" && fail "generation-restart.sh contains a force-push" || true

# (8) idempotency — a re-run (crash AFTER the CAS) no-ops and does not move the ref
BEFORE=$(git rev-parse "feature/$SLUG")
RJSON2=$(bash "$GR" --repo "$TMP/feat" --slug "$SLUG" --epic epic --feature "feature/$SLUG" \
  --expect-tip "$EXPECT" --to-generation 2 --batch-id RB-0001 --contract-dir "$TMP/newc" \
  --feature-state "$TMP/feat/.parallax/$SLUG/feature-state.json" \
  --receipt "$TMP/feat/.parallax/$SLUG/resolutions/RB-0001.json" --remote origin) || fail "idempotent re-run exited non-zero: $RJSON2"
echo "$RJSON2" | grep -q '"decision":"noop"' || fail "re-run was not a no-op: $RJSON2"
[ "$(git rev-parse "feature/$SLUG")" = "$BEFORE" ] || fail "idempotent re-run moved the feature ref"

# (9) a stale expected-tip (a crash/lost view BEFORE the CAS) refuses and leaves the feature ref untouched
BEFORE2=$(git rev-parse "feature/$SLUG")
bash "$GR" --repo "$TMP/feat" --slug "$SLUG" --epic epic --feature "feature/$SLUG" \
  --expect-tip "$EXPECT" --to-generation 3 --batch-id RB-0002 --contract-dir "$TMP/newc" \
  --feature-state "$TMP/feat/.parallax/$SLUG/feature-state.json" \
  --receipt "$TMP/feat/.parallax/$SLUG/resolutions/RB-0001.json" --remote origin >/tmp/parallax_grstale 2>&1
RC=$?
[ "$RC" = 9 ] || fail "stale expected-tip should exit 9 (got $RC): $(cat /tmp/parallax_grstale)"
[ "$(git rev-parse "feature/$SLUG")" = "$BEFORE2" ] || fail "stale expected-tip moved the feature ref"

echo "t_resolution_generation OK (append-only restart: fresh epic base, no old code on active paths, history archived, gen-2 contract installed, fast-forward publish, idempotent, stale-tip refusal)"
