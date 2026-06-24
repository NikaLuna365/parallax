#!/usr/bin/env bash
# v0.31 P2 — EXECUTES scripts/generation-restart.sh under a CONCURRENT-resolver race (DESIGN §12 step 6 / §18.5):
# two resolvers, each having observed the SAME parked tip, try to land a generation-2 restart. The atomic
# feature-ref compare-and-swap lets EXACTLY ONE win; the loser refuses to clobber; the surviving advance is
# append-only (a fast-forward of the old tip, no history rewrite). Also asserts the raw CAS primitive
# (git update-ref <ref> <new> <old>) rejects a stale expected-old — which is what makes the winner unique.
# Exit: 0 behaved, 2 SKIP (no jsonschema), 1 a case wrong.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
RES="$PLUGIN/scripts/resolution.py"; GR="$PLUGIN/scripts/generation-restart.sh"
python3 -c "import jsonschema" 2>/dev/null || { echo "SKIP"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail(){ echo "FAIL: $*"; exit 1; }
SLUG=demo
H64="$(printf 'a%.0s' $(seq 1 64))"; N64="$(printf 'b%.0s' $(seq 1 64))"; C64="$(printf 'c%.0s' $(seq 1 64))"

git init -q --bare -b epic "$TMP/epic.git"
git init -q "$TMP/seed"; ( cd "$TMP/seed"; git config user.email t@t; git config user.name t
  mkdir src; echo base > src/base.ts; git add -A; git commit -q -m base; git branch -M epic
  git remote add origin "$TMP/epic.git"; git push -q origin epic )

git clone -q "$TMP/epic.git" "$TMP/feat"; cd "$TMP/feat"; git config user.email t@t; git config user.name t
git switch -q -c "feature/$SLUG" origin/epic
git branch -q epic origin/epic                       # a local epic ref so the script resolves --epic without a remote
mkdir -p ".parallax/$SLUG"; echo impl > src/old.ts
printf 's1\n' > ".parallax/$SLUG/spec.md"; printf 'sl\n' > ".parallax/$SLUG/slices.md"; printf 'v\n' > ".parallax/$SLUG/validation.md"
printf '{"slug":"demo","slices":["S1"]}\n' > ".parallax/$SLUG/slices.lock"
python3 "$RES" init-feature ".parallax/$SLUG/feature-state.json" --slug "$SLUG" --feature-id F1 \
  --run-id RUN1 --base-oid "$(git rev-parse HEAD)" --tip-oid "$(git rev-parse HEAD)" --contract-hash "$H64" >/dev/null
git add -A; git commit -q -m "parked gen1"
git switch -q --detach "feature/$SLUG"
OLD=$(git rev-parse "feature/$SLUG")

mkdir "$TMP/c"; for f in spec.md slices.md validation.md; do echo "gen2 $f" > "$TMP/c/$f"; done
printf '{"slug":"demo","slices":["S1"]}\n' > "$TMP/c/slices.lock"

# Each resolver prepares a DISTINCT generation-2 feature-state + receipt (different new_run_id + batch id), so
# their restart commits are different objects — the CAS, not luck, is what picks the single winner.
mkfs(){ # $1=batch  $2=new_run_id  -> writes $TMP/$1/{feature-state.json,resolutions/$1.json}
  local d="$TMP/$1"; mkdir -p "$d/resolutions"
  python3 - "$TMP/feat/.parallax/$SLUG/feature-state.json" "$d/feature-state.json" "$2" "$1" <<'PY'
import json,sys
src,dst,run,batch=sys.argv[1:5]
d=json.load(open(src)); d.update(generation=2,active_run_id=run,parent_run_id="RUN1",
  contract_hash="b"*64,status="running",resolution_chain=[batch]); json.dump(d,open(dst,"w"))
PY
  printf '{"schema_version":1,"batch_id":"%s","slug":"demo","from_generation":1,"to_generation":2,"source_run_id":"RUN1","new_run_id":"%s","source_contract_hash":"%s","new_contract_hash":"%s","item_decisions":[{"item_id":"R-S1-0001","decision":"choose-option"}],"exact_human_text":"x","confirmation_token":"PARALLAX-RESOLVE:demo:g1->g2:%s:aaaaaaaaaaaa:bbbbbbbbbbbb","contract_diff_hash":"%s","invalidation_scope":"all-slices","created_at":"t","status":"applied"}\n' \
    "$1" "$2" "$H64" "$N64" "$1" "$C64" > "$d/resolutions/$1.json"
}
mkfs RB-0001 RUN2
mkfs RB-0002 RUN3

run_one(){ # $1=batch — both pass --expect-tip OLD, modelling two resolvers that read the same parked tip
  bash "$GR" --repo "$TMP/feat" --slug "$SLUG" --epic epic --feature "feature/$SLUG" \
    --expect-tip "$OLD" --to-generation 2 --batch-id "$1" --contract-dir "$TMP/c" \
    --feature-state "$TMP/$1/feature-state.json" --receipt "$TMP/$1/resolutions/$1.json"
}

R1=$(run_one RB-0001 2>/dev/null); rc1=$?      # first to reach the CAS wins
R2=$(run_one RB-0002 2>&1);        rc2=$?      # second observes the moved ref and refuses
WIN=$(git -C "$TMP/feat" rev-parse "feature/$SLUG")

[ "$rc1" = 0 ] || fail "first resolver should win (rc=$rc1): $R1"
[ "$rc2" = 9 ] || fail "second resolver should lose with rc=9 (got rc=$rc2): $R2"
W1=$(echo "$R1" | python3 -c "import json,sys; print(json.load(sys.stdin)['restart_oid'])")
[ "$WIN" = "$W1" ] || fail "feature ref is not the first resolver's restart (got $WIN want $W1)"
echo "$R2" | grep -q 'race-lost' || fail "loser did not report a race loss: $R2"
git -C "$TMP/feat" merge-base --is-ancestor "$OLD" "$WIN" || fail "winning advance is not append-only (old tip is not an ancestor)"

# the raw CAS primitive the winner relied on rejects a stale expected-old (would otherwise clobber the winner)
if git -C "$TMP/feat" update-ref "refs/heads/feature/$SLUG" "$OLD" "$OLD" 2>/dev/null; then
  fail "git update-ref CAS accepted a stale expected-old — the feature ref is not race-safe"
fi
[ "$(git -C "$TMP/feat" rev-parse "feature/$SLUG")" = "$WIN" ] || fail "feature ref changed after the rejected CAS"

echo "t_resolution_race OK (atomic feature-ref CAS: exactly one resolver lands generation 2; the loser refuses; append-only, no force)"
