#!/usr/bin/env bash
# v0.37.3 F1 — EXECUTES scripts/blindfold-guard.py --scope-manifest against a REAL
# pnpm-style monorepo fixture (packages/app imports packages/shared). Locks:
#   1. test side PASSES when the sibling package's src + dist are tracked (needed for
#      cross-package import resolution, allowed via dependency_allow_globs) while the
#      slice's OWN new implementation file is absent;
#   2. test side FAILS CLOSED (exit 2, marked protected) once that own-impl file appears —
#      even though dependency globs are in force;
#   3. a protected impl path covered BY a dependency glob still fails closed (protected
#      wins over every allowlist);
#   4. code side fails closed on the slice's own protected test file;
#   5. .parallax/<slug>/spec.md is never a test/impl leak — in strict AND monorepo mode;
#   6. bin/ is NOT compiled output by default; an explicit --compiled-glob 'bin/**' makes
#      it one again for repos where bin/ is generated;
#   7. a whole-tree '**' (or '**/*') dependency glob is rejected by the manifest schema;
#   8. a slug/manifest mismatch and an unreadable manifest are bad input (exit 3), never a
#      silent fallback to strict mode;
#   9. the pre-existing strict-mode fixture (tests/t_blindfold.sh) still passes unchanged.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; G="$PLUGIN/scripts/blindfold-guard.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk(){ git init -q "$1"; git -C "$1" config user.email t@t; git -C "$1" config user.name t; }
ci(){ git -C "$1" add -A; git -C "$1" commit -q -m x; }
fail(){ echo "FAIL: $1"; exit 1; }
python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo "t_blindfold_monorepo SKIP (jsonschema not installed — guard itself fails closed without it)"; exit 2; }

SCOPE="$T/scope.json"
cat > "$SCOPE" <<'JSON'
{
  "schema_version": "parallax-blindfold-scope-v1",
  "slug": "demo",
  "slice_id": "S1",
  "protected_impl_paths": ["packages/app/src/new-screen.tsx"],
  "protected_test_paths": ["packages/app/src/new-screen.test.tsx"],
  "dependency_allow_globs": ["packages/shared/src/**", "packages/shared/dist/**"]
}
JSON

# --- monorepo test worktree: sibling src + dist present, the app package's EXISTING base
#     source present (a real monorepo checkout resolves imports through it), own new impl
#     ABSENT, shared spec.md present -> PASS
mk "$T/mono"
mkdir -p "$T/mono/packages/shared/src" "$T/mono/packages/shared/dist" \
         "$T/mono/packages/app/src" "$T/mono/.parallax/demo"
echo 'export const shared = 1;'    > "$T/mono/packages/shared/src/index.ts"
echo 'exports.shared = 1;'         > "$T/mono/packages/shared/dist/index.js"
echo 'export const existing = 1;'  > "$T/mono/packages/app/src/existing-base.tsx"
echo 'test("x", () => {});'        > "$T/mono/packages/app/src/new-screen.test.tsx"
echo '# frozen contract'           > "$T/mono/.parallax/demo/spec.md"
ci "$T/mono"
OUT=$(python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$SCOPE"); RC=$?
[ "$RC" -eq 0 ] || fail "1: monorepo test worktree with sibling src/dist + existing base tree + no own-impl was rejected (rc=$RC): $OUT"
echo "$OUT" | grep -qF '"mode": "slice-scoped"' || fail "1: guard did not report slice-scoped mode: $OUT"
echo "$OUT" | grep -qF 'spec.md' && fail "5a: .parallax/demo/spec.md leaked into a clean verdict: $OUT"
# the slice's own package dist/ is still compiled output (NOT covered by the sibling globs)
mkdir -p "$T/mono/packages/app/dist"; echo 'x' > "$T/mono/packages/app/dist/new-screen.js"; ci "$T/mono"
OUT=$(python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$SCOPE"); RC=$?
[ "$RC" -eq 2 ] || fail "1b: the slice's own package dist/ passed in slice-scoped mode (rc=$RC): $OUT"
git -C "$T/mono" rm -q -r packages/app/dist; ci "$T/mono"

# --- 2) add the slice's OWN new implementation file -> reject, marked protected
echo 'export function NewScreen(){}' > "$T/mono/packages/app/src/new-screen.tsx"
ci "$T/mono"
OUT=$(python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$SCOPE"); RC=$?
[ "$RC" -eq 2 ] || fail "2: own-impl leak in monorepo mode was NOT rejected (rc=$RC): $OUT"
echo "$OUT" | grep -qF 'packages/app/src/new-screen.tsx' || fail "2: verdict does not name the protected file: $OUT"
echo "$OUT" | grep -qF '"protected": true' || fail "2: leak not marked protected: $OUT"

# --- 3) a dependency glob that COVERS the protected impl path still cannot mask it
SCOPE3="$T/scope3.json"
python3 - "$SCOPE" "$SCOPE3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["dependency_allow_globs"] = ["packages/app/src/**"]     # covers the protected file
json.dump(d, open(sys.argv[2], "w"))
PY
OUT=$(python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$SCOPE3"); RC=$?
[ "$RC" -eq 2 ] || fail "3: a dependency glob masked a protected impl path (rc=$RC): $OUT"
echo "$OUT" | grep -qF '"protected": true' || fail "3: protected-wins verdict missing: $OUT"

# --- 4) code side: the slice's own protected test file fails closed
mk "$T/mono-code"
mkdir -p "$T/mono-code/packages/app/src" "$T/mono-code/packages/shared/src"
echo 'export const shared = 1;'      > "$T/mono-code/packages/shared/src/index.ts"
echo 'export function NewScreen(){}' > "$T/mono-code/packages/app/src/new-screen.tsx"
echo 'test("x", () => {});'          > "$T/mono-code/packages/app/src/new-screen.test.tsx"
ci "$T/mono-code"
OUT=$(python3 "$G" --worktree "$T/mono-code" --side code --slug demo --scope-manifest "$SCOPE"); RC=$?
[ "$RC" -eq 2 ] || fail "4: code side did not reject the slice's own test file (rc=$RC): $OUT"
echo "$OUT" | grep -qF 'new-screen.test.tsx' || fail "4: verdict does not name the test leak: $OUT"
git -C "$T/mono-code" rm -q packages/app/src/new-screen.test.tsx; ci "$T/mono-code"
python3 "$G" --worktree "$T/mono-code" --side code --slug demo --scope-manifest "$SCOPE" >/dev/null; RC=$?
[ "$RC" -eq 0 ] || fail "4b: clean monorepo code worktree rejected (rc=$RC)"

# --- 5b) .parallax/<slug>/spec.md is not a leak in STRICT mode either (the default fix)
mk "$T/strict"
mkdir -p "$T/strict/.parallax/demo" "$T/strict/src"
echo '# frozen contract'        > "$T/strict/.parallax/demo/spec.md"
echo 'def add(a,b): return a+b' > "$T/strict/src/calc.py"
ci "$T/strict"
# code side: the only test-shaped path is .parallax/demo/spec.md (bare "spec" stem) -> must pass
python3 "$G" --worktree "$T/strict" --side code --slug demo >/dev/null; RC=$?
[ "$RC" -eq 0 ] || fail "5b: .parallax/demo/spec.md misclassified as a test leak on the code side (strict mode)"
# test side: .parallax/ evidence/reviews artifacts are not impl/compiled leaks either
mk "$T/strict-t"
mkdir -p "$T/strict-t/.parallax/demo/evidence" "$T/strict-t/tests"
echo '# frozen contract'  > "$T/strict-t/.parallax/demo/spec.md"
echo '{"run_id":"r"}'     > "$T/strict-t/.parallax/demo/evidence/run-evidence.json"
echo 'def test_x(): pass' > "$T/strict-t/tests/test_x.py"
ci "$T/strict-t"
python3 "$G" --worktree "$T/strict-t" --side test --slug demo >/dev/null; RC=$?
[ "$RC" -eq 0 ] || fail "5c: .parallax/** artifacts misclassified as impl/compiled on the test side (strict mode)"

# --- 6) bin/ default: ordinary tracked scripts in bin/ are NOT compiled output …
mk "$T/bindir"
mkdir -p "$T/bindir/bin" "$T/bindir/tests"
printf '#!/bin/sh\necho hi\n'    > "$T/bindir/bin/tool"
echo 'def test_x(): assert True' > "$T/bindir/tests/test_x.py"
ci "$T/bindir"
python3 "$G" --worktree "$T/bindir" --side test --slug demo >/dev/null; RC=$?
[ "$RC" -eq 0 ] || fail "6: bin/tool treated as compiled output by DEFAULT (rc=$RC)"
# … but an explicit --compiled-glob 'bin/**' makes bin/ compiled again
OUT=$(python3 "$G" --worktree "$T/bindir" --side test --slug demo --compiled-glob 'bin/**'); RC=$?
[ "$RC" -eq 2 ] || fail "6b: --compiled-glob 'bin/**' did not reject bin/tool (rc=$RC): $OUT"
echo "$OUT" | grep -qF 'compiled-build-output-visible-to-test-writer' || fail "6b: wrong reason for bin/ rejection: $OUT"

# --- 7) a whole-tree dependency glob is schema-rejected ('**' and '**/*' alike)
for BAD in '**' '**/*'; do
  BADSCOPE="$T/bad.json"
  python3 - "$SCOPE" "$BADSCOPE" "$BAD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["dependency_allow_globs"] = [sys.argv[3]]
json.dump(d, open(sys.argv[2], "w"))
PY
  python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$BADSCOPE" >/dev/null; RC=$?
  [ "$RC" -eq 3 ] || fail "7: whole-tree dependency glob '$BAD' was NOT rejected (rc=$RC)"
done

# --- 8) slug mismatch and unreadable manifest are bad input (exit 3), never silent strict fallback
python3 "$G" --worktree "$T/mono" --side test --slug OTHER --scope-manifest "$SCOPE" >/dev/null; RC=$?
[ "$RC" -eq 3 ] || fail "8: slug/manifest mismatch not rejected as bad input (rc=$RC)"
python3 "$G" --worktree "$T/mono" --side test --slug demo --scope-manifest "$T/nope.json" >/dev/null; RC=$?
[ "$RC" -eq 3 ] || fail "8b: missing manifest not rejected as bad input (rc=$RC)"

# --- 9) the pre-existing strict-mode fixture still passes unchanged
bash "$PLUGIN/tests/t_blindfold.sh" >/tmp/parallax_bf_regress 2>&1 || fail "9: tests/t_blindfold.sh regressed: $(cat /tmp/parallax_bf_regress)"

echo "t_blindfold_monorepo OK"
