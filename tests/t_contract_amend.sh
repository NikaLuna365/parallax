#!/usr/bin/env bash
# v0.37 P0.4 — EXECUTES scripts/contract-amend.py verify. An unchanged frozen contract is ok; a
# direct in-place post-freeze contract edit with NO amendment is rejected; the sanctioned
# mechanical-tightening path (an amendment whose prev/new hashes chain frozen->current, with all
# propagation flags true and a pre-freeze pass) is accepted; an amendment with incomplete
# propagation is rejected.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; CA="$PLUGIN/scripts/contract-amend.py"; CH="$PLUGIN/scripts/contract-hash.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
R="$T/repo"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/.parallax/demo"
printf 'spec v1: rounding HALF_UP\n' > "$R/.parallax/demo/spec.md"
echo 'S1' > "$R/.parallax/demo/slices.md"
echo 'full: npm test' > "$R/.parallax/demo/validation.md"
echo '{"slug":"demo","slices":["S1"]}' > "$R/.parallax/demo/slices.lock"
git -C "$R" add -A; git -C "$R" commit -q -m freeze
FROZEN=$(bash "$CH" HEAD demo "$R")

# (0) unchanged contract -> ok (exit 0)
python3 "$CA" verify --repo "$R" --ref HEAD --slug demo --frozen-hash "$FROZEN" >/dev/null; [ $? -eq 0 ] || fail "unchanged contract rejected"

# (1) direct post-freeze edit, NO amendment -> reject (exit 2)
printf 'spec v1: rounding HALF_UP; also clamp negative to 0\n' > "$R/.parallax/demo/spec.md"
git -C "$R" add -A; git -C "$R" commit -q -m "sneaky in-place edit"
python3 "$CA" verify --repo "$R" --ref HEAD --slug demo --frozen-hash "$FROZEN" >/dev/null; [ $? -eq 2 ] || fail "unsanctioned post-freeze edit not rejected"
NEW=$(bash "$CH" HEAD demo "$R")

# (2) sanctioned amendment frozen->current -> accept (exit 0)
mkdir -p "$R/.parallax/demo/amendments"
cat > "$R/.parallax/demo/amendments/CA-1.json" <<EOF
{ "schema_version":"parallax-contract-amendment-v1","slug":"demo","amendment_id":"CA-1",
  "kind":"mechanical-tightening","rationale":"spec under-scoped the negative clamp; one correct reading",
  "evidence":["spec.md:1"],"prev_contract_hash":"$FROZEN","new_contract_hash":"$NEW",
  "prefreeze_review":{"verdict":"pass"},
  "propagation":{"examples":true,"acceptance":true,"public_interface":true,"blast_radius":true,"validation":true,"slice_seams":true} }
EOF
git -C "$R" add -A; git -C "$R" commit -q -m "CA-1"
python3 "$CA" verify --repo "$R" --ref HEAD --slug demo --frozen-hash "$FROZEN" >/dev/null; [ $? -eq 0 ] || fail "sanctioned tightening not accepted"

# (3) amendment with an incomplete propagation -> reject (exit 2)
cat > "$R/.parallax/demo/amendments/CA-1.json" <<EOF
{ "schema_version":"parallax-contract-amendment-v1","slug":"demo","amendment_id":"CA-1",
  "kind":"mechanical-tightening","rationale":"x","evidence":["spec.md:1"],
  "prev_contract_hash":"$FROZEN","new_contract_hash":"$NEW","prefreeze_review":{"verdict":"pass"},
  "propagation":{"examples":true,"acceptance":true,"public_interface":true,"blast_radius":true,"validation":true,"slice_seams":false} }
EOF
git -C "$R" add -A; git -C "$R" commit -q -m "CA-1 incomplete"
python3 "$CA" verify --repo "$R" --ref HEAD --slug demo --frozen-hash "$FROZEN" >/dev/null; [ $? -eq 2 ] || fail "incomplete-propagation amendment not rejected"

echo "t_contract_amend OK"
