#!/usr/bin/env bash
# v0.37.3 F4 — EXECUTES scripts/merge-ledger.py --repo-root against a REAL git repo. Locks:
#   1. basename drift: round 1 records a finding at packages/app/src/StorageSubscreen.test.tsx:882,
#      round 2 resolves it citing only StorageSubscreen.test.tsx:882 -> the SAME finding is
#      settled (fixed), no phantom duplicate, nothing left unresolved (the live-run F4 bug);
#   2. re-reporting with a drifted path binds to the same ledger id (no duplicate finding);
#   3. sub-path drift (src/StorageSubscreen.test.tsx) also canonicalizes;
#   4. an AMBIGUOUS basename (two tracked dup.ts) is NOT silently merged: kept distinct,
#      surfaced via path_warnings + stderr;
#   5. a bad --repo-root is a hard error (exit 3), never a silent fall-back;
#   6. cited-id consistency still holds under canonicalization (a drifted-path resolved
#      citing the RIGHT id settles it; the v0.22 mismatched-id guard still refuses a wrong id);
#   7. without --repo-root, behavior is unchanged (drift still splits — the strict legacy mode).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; M="$PLUGIN/scripts/merge-ledger.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }

# repo fixture: the monorepo file + two files sharing a basename
git init -q "$T/repo"; git -C "$T/repo" config user.email t@t; git -C "$T/repo" config user.name t
mkdir -p "$T/repo/packages/app/src" "$T/repo/a" "$T/repo/b"
echo x > "$T/repo/packages/app/src/StorageSubscreen.test.tsx"
echo x > "$T/repo/a/dup.ts"; echo x > "$T/repo/b/dup.ts"
git -C "$T/repo" add -A; git -C "$T/repo" commit -q -m x
L="$T/ledger.json"

# round 1: full repo-relative path
cat > "$T/r1.json" <<'JSON'
{"verdict":"concerns","findings":[
  {"severity":"high","kind":"test-fault","spec_ref":"B4","where":"packages/app/src/StorageSubscreen.test.tsx:882",
   "claim":"assertion mis-encodes rounding","evidence":"expects 200, spec says 210"}]}
JSON
python3 "$M" "$L" "$T/r1.json" --slice S1 --current-diff d1 --slug demo --repo-root "$T/repo" --raw-response "$T/r1.json" >/dev/null || fail "1: round1 merge failed"

# --- 1) round 2 resolves the same finding citing ONLY the basename -> fixed, no dup
cat > "$T/r2.json" <<'JSON'
{"verdict":"pass","findings":[],"resolved":[
  {"kind":"test-fault","spec_ref":"B4","where":"StorageSubscreen.test.tsx:882","note":"re-verified fixed"}]}
JSON
python3 "$M" "$L" "$T/r2.json" --slice S1 --current-diff d2 --slug demo --repo-root "$T/repo" --raw-response "$T/r2.json" >/dev/null || fail "1: round2 merge failed"
python3 - "$L" <<'PY' || fail "1: basename drift split or failed to settle the finding"
import json,sys
l=json.load(open(sys.argv[1]))
assert len(l["findings"])==1, [f["id"] for f in l["findings"]]      # no phantom duplicate
f=l["findings"][0]
assert f["status"]=="fixed" and f["verified_by"]=="codex" and f["last_verified_diff"]=="d2", f
PY

# --- 2) re-REPORTING with a drifted path binds to the same id (regressed, not a new finding)
cat > "$T/r3.json" <<'JSON'
{"verdict":"concerns","findings":[
  {"severity":"high","kind":"test-fault","spec_ref":"B4","where":"StorageSubscreen.test.tsx:882",
   "claim":"back again","evidence":"same assertion"}]}
JSON
python3 "$M" "$L" "$T/r3.json" --slice S1 --current-diff d3 --slug demo --repo-root "$T/repo" --raw-response "$T/r3.json" >/dev/null || fail "2: round3 merge failed"
python3 - "$L" <<'PY' || fail "2: drifted re-report minted a duplicate instead of regressing the same finding"
import json,sys
l=json.load(open(sys.argv[1]))
assert len(l["findings"])==1, [f["id"] for f in l["findings"]]
assert l["findings"][0]["status"]=="regressed", l["findings"][0]["status"]
PY

# --- 3) sub-path drift (src/…) canonicalizes too
cat > "$T/r4.json" <<'JSON'
{"verdict":"pass","findings":[],"resolved":[
  {"kind":"test-fault","spec_ref":"B4","where":"src/StorageSubscreen.test.tsx:882","note":"fixed again"}]}
JSON
python3 "$M" "$L" "$T/r4.json" --slice S1 --current-diff d4 --slug demo --repo-root "$T/repo" --raw-response "$T/r4.json" >/dev/null || fail "3: round4 merge failed"
python3 - "$L" <<'PY' || fail "3: sub-path drift did not settle the same finding"
import json,sys
l=json.load(open(sys.argv[1]))
assert len(l["findings"])==1 and l["findings"][0]["status"]=="fixed"
PY

# --- 4) ambiguous basename: kept distinct + loud warning, never silently merged
mkdir -p "$T/amb"; LA="$T/amb/ledger.json"   # own dir: canonical raw names are per-reviews-dir
cat > "$T/a1.json" <<'JSON'
{"verdict":"concerns","findings":[
  {"severity":"medium","kind":"code-fault","spec_ref":"B1","where":"a/dup.ts:1","claim":"c1","evidence":"e1"}]}
JSON
python3 "$M" "$LA" "$T/a1.json" --slice S1 --current-diff d1 --slug demo --repo-root "$T/repo" --raw-response "$T/a1.json" >/dev/null 2>&1 || fail "4: ambiguous round1 failed"
cat > "$T/a2.json" <<'JSON'
{"verdict":"pass","findings":[],"resolved":[
  {"kind":"code-fault","spec_ref":"B1","where":"dup.ts:1","note":"claims fixed"}]}
JSON
OUT=$(python3 "$M" "$LA" "$T/a2.json" --slice S1 --current-diff d2 --slug demo --repo-root "$T/repo" --raw-response "$T/a2.json" 2>/tmp/parallax_mlpd_err) || fail "4: ambiguous round2 failed"
echo "$OUT" | grep -qF 'path_warnings' || fail "4: no path_warnings in summary for an ambiguous basename: $OUT"
grep -qiF 'ambiguous' /tmp/parallax_mlpd_err || fail "4: no stderr warning for an ambiguous basename"
python3 - "$LA" <<'PY' || fail "4: an ambiguous basename silently settled a finding it could not identify"
import json,sys
l=json.load(open(sys.argv[1]))
assert len(l["findings"])==1
assert l["findings"][0]["status"]=="open", l["findings"][0]   # bare dup.ts must NOT close a/dup.ts
PY

# --- 5) a bad --repo-root is a hard error, never a silent string-identity fallback
python3 "$M" "$T/x.json" "$T/r1.json" --slice S1 --current-diff d1 --repo-root "$T/norepo" >/tmp/parallax_mlpd5 2>/dev/null; RC=$?
[ "$RC" -eq 3 ] || fail "5: bad --repo-root not rejected (rc=$RC)"
grep -qF 'canonicalization unavailable' /tmp/parallax_mlpd5 || fail "5: wrong error: $(cat /tmp/parallax_mlpd5)"

# --- 6) cited-id + canonicalization: a drifted-path resolve citing the RIGHT id settles it;
#        citing an id whose metadata mismatches still falls back (cannot close the wrong one)
mkdir -p "$T/id1"; LB="$T/id1/ledger.json"
python3 "$M" "$LB" "$T/r1.json" --slice S1 --current-diff d1 --slug demo --repo-root "$T/repo" --raw-response "$T/r1.json" >/dev/null || fail "6: seed failed"
FID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings"][0]["id"])' "$LB")
cat > "$T/r6.json" <<JSON
{"verdict":"pass","findings":[],"resolved":[
  {"id":"$FID","kind":"test-fault","spec_ref":"B4","where":"StorageSubscreen.test.tsx:900","note":"fixed"}]}
JSON
python3 "$M" "$LB" "$T/r6.json" --slice S1 --current-diff d2 --slug demo --repo-root "$T/repo" --raw-response "$T/r6.json" >/dev/null || fail "6: cited-id merge failed"
python3 - "$LB" <<'PY' || fail "6: cited id + drifted path did not settle the finding"
import json,sys
l=json.load(open(sys.argv[1])); f=l["findings"][0]
assert f["status"]=="fixed" and f["verified_by"]=="codex"
PY
mkdir -p "$T/id2"; LB2="$T/id2/ledger.json"
python3 "$M" "$LB2" "$T/r1.json" --slice S1 --current-diff d1 --slug demo --repo-root "$T/repo" --raw-response "$T/r1.json" >/dev/null
FID2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings"][0]["id"])' "$LB2")
cat > "$T/r7.json" <<JSON
{"verdict":"pass","findings":[],"resolved":[
  {"id":"$FID2","kind":"code-fault","spec_ref":"OTHER","where":"a/dup.ts:5","note":"wrong metadata"}]}
JSON
python3 "$M" "$LB2" "$T/r7.json" --slice S1 --current-diff d2 --slug demo --repo-root "$T/repo" --raw-response "$T/r7.json" >/dev/null 2>/dev/null
python3 - "$LB2" <<'PY' || fail "6b: a cited id with mismatched metadata closed the wrong finding"
import json,sys
l=json.load(open(sys.argv[1]))
assert l["findings"][0]["status"]=="open", l["findings"][0]
PY

# --- 7) legacy mode (no --repo-root) is unchanged: drift still splits
mkdir -p "$T/leg"; LC="$T/leg/ledger.json"
python3 "$M" "$LC" "$T/r1.json" --slice S1 --current-diff d1 --slug demo --raw-response "$T/r1.json" >/dev/null || fail "7: legacy round1 failed"
python3 "$M" "$LC" "$T/r3.json" --slice S1 --current-diff d2 --slug demo --raw-response "$T/r3.json" >/dev/null || fail "7: legacy round2 failed"
python3 - "$LC" <<'PY' || fail "7: legacy (no --repo-root) behavior changed"
import json,sys
l=json.load(open(sys.argv[1]))
assert len(l["findings"])==2, [f["id"] for f in l["findings"]]   # exact-string identity, as v0.37.2
PY

echo "t_merge_ledger_path_drift OK"
