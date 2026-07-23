#!/usr/bin/env bash
# TZ v0.41 §5.9 (PR1): the release path refuses to package a version that has
# no durable independent verifier verdict. Drives the actual packaging path.
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

REPO="$T/release-repo"
mkdir -p "$REPO/.claude-plugin"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf '{"name": "parallax", "version": "9.9.9", "description": "scratch"}\n' > "$REPO/.claude-plugin/plugin.json"
printf 'content\n' > "$REPO/file.txt"
git -C "$REPO" add .; git -C "$REPO" commit -qm base

# PR1a: packaging with NO review file fails with a clear message.
if python3 "$PLUGIN/scripts/release-gate.py" package --repo "$REPO" --reviews-dir "$T/REVIEWS" --output-dir "$T/out" > "$T/pr1a.out" 2>&1; then
  fail 'PR1: packaging proceeded with no verifier verdict on disk'
fi
grep -q 'no durable verifier verdict' "$T/pr1a.out" || { cat "$T/pr1a.out"; fail 'PR1: refusal message unclear'; }
[ ! -e "$T/out/plugin_Parallax_v9.9.9.zip" ] || fail 'PR1: a zip was produced despite the refusal'

# PR1b: a FAIL verdict also refuses to package.
mkdir -p "$T/REVIEWS"
python3 - "$T/REVIEWS/v9.9.9_implementation_verification.md" FAIL <<'PY'
import sys
body = ("# v9.9.9 implementation verification\n\nIndependent verifier report. " * 8 +
        f"\n\nVerdict: {sys.argv[2]}\n")
open(sys.argv[1], 'w').write(body)
PY
if python3 "$PLUGIN/scripts/release-gate.py" package --repo "$REPO" --reviews-dir "$T/REVIEWS" --output-dir "$T/out" > "$T/pr1b.out" 2>&1; then
  fail 'PR1: a FAIL verdict was packaged'
fi
grep -q 'FAIL' "$T/pr1b.out" || fail 'PR1: FAIL refusal does not name the verdict'

# PR1c: adding a PASS verdict lets the package proceed and produces artifacts.
python3 - "$T/REVIEWS/v9.9.9_implementation_verification.md" PASS <<'PY'
import sys
body = ("# v9.9.9 implementation verification\n\nIndependent verifier report with commands and cited output. " * 8 +
        f"\n\nVerdict: {sys.argv[2]}\n")
open(sys.argv[1], 'w').write(body)
PY
python3 "$PLUGIN/scripts/release-gate.py" package --repo "$REPO" --reviews-dir "$T/REVIEWS" --output-dir "$T/out" > "$T/pr1c.out" \
  || { cat "$T/pr1c.out"; fail 'PR1: packaging failed with a valid PASS verdict present'; }
[ -s "$T/out/plugin_Parallax_v9.9.9.zip" ] || fail 'PR1: zip missing after gate passed'
[ -s "$T/out/SHA256SUMS.v9.9.9" ] || fail 'PR1: SHA256SUMS missing after gate passed'
python3 - "$T/out" <<'PY'
import hashlib, sys
from pathlib import Path
out = Path(sys.argv[1])
digest, name = out.joinpath('SHA256SUMS.v9.9.9').read_text().split()
assert name == 'plugin_Parallax_v9.9.9.zip'
assert hashlib.sha256((out / name).read_bytes()).hexdigest() == digest, 'recorded sha does not match the artifact'
PY

# PR1d: `check` is the same gate without packaging.
rm "$T/REVIEWS/v9.9.9_implementation_verification.md"
if python3 "$PLUGIN/scripts/release-gate.py" check --repo "$REPO" --reviews-dir "$T/REVIEWS" > /dev/null 2>&1; then
  fail 'PR1: check passed with no verdict file'
fi

echo 't_release_gate OK'
