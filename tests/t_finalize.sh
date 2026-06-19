#!/usr/bin/env bash
# v0.25 P1#3 — EXECUTES the completion-receipt finalization with $ROOT DETACHED (the parallel/autonomous
# topology). The receipt must land ON feature/<slug> via the transient-worktree + CAS update-ref, NOT on a
# dangling detached HEAD (where the gate would read status!=complete and HOLD a correct run).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; TH="$PLUGIN/scripts/code-tree-hash.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT="$TMP/repo"; git init -q "$ROOT"; git -C "$ROOT" config user.email t@t; git -C "$ROOT" config user.name t
mkdir -p "$ROOT/src" "$ROOT/.parallax/demo"; echo code>"$ROOT/src/a.ts"
printf '%s' '{"run_id":"r","slug":"demo","epic":"feature/epic","base_tip":"dddddddddddddddddddddddddddddddddddddddd","status":"running","slices":[{"id":"S1","status":"integrated"}],"updated_at":"t","lock":{"holder":"r","acquired_at":"t","expires_at":"t2"}}' > "$ROOT/.parallax/demo/run-state.json"
git -C "$ROOT" add -A; git -C "$ROOT" commit -q -m base
git -C "$ROOT" branch -M feature/demo
# parallel/autonomous topology: $ROOT sits DETACHED at the integration tip
git -C "$ROOT" switch -q --detach feature/demo
TIP_REF="feature/demo"; TIP=$(git -C "$ROOT" rev-parse "$TIP_REF")

# --- the run.md Step 4 finalization mechanic (transient detached worktree + CAS) ---
FWT="$TMP/finalize"
git -C "$ROOT" worktree add -q --detach "$FWT" "$TIP"
VT=$(bash "$TH" HEAD "$FWT")
python3 - "$FWT/.parallax/demo/run-state.json" "$VT" <<'PY'
import json,sys
p,vt=sys.argv[1],sys.argv[2]
d=json.load(open(p)); d["status"]="complete"; d["verified_tree"]=vt; d.pop("lock",None)
json.dump(d,open(p,"w"))
PY
( cd "$FWT" && git add -- .parallax/demo/run-state.json && git commit -q -m "complete" )
git -C "$ROOT" update-ref "refs/heads/$TIP_REF" "$(git -C "$FWT" rev-parse HEAD)" "$TIP"
git -C "$ROOT" worktree remove --force "$FWT"

# --- assert the receipt is ON feature/demo (read the ref, not any worktree) ---
ST=$(git -C "$ROOT" show "$TIP_REF:.parallax/demo/run-state.json" | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
[ "$ST" = complete ] || { echo "FAIL: feature ref run-state status=$ST — receipt not on feature/<slug>"; exit 1; }
git -C "$ROOT" merge-base --is-ancestor "$TIP" "$TIP_REF" || { echo "FAIL: feature ref did not advance from the old tip"; exit 1; }
echo "t_finalize OK (completion receipt landed on feature/demo via worktree+CAS, with \$ROOT detached)"
