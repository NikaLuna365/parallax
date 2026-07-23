#!/usr/bin/env python3
"""Release gate: no tag, no package without a durable independent verdict.

The v0.40 band shipped eight versions with zero durable verifier verdicts
(REVIEWS/v0.40_band_retro_verification.md §1). This script makes the missing
discipline mechanical: packaging (or tagging) version X.Y.Z REQUIRES
`REVIEWS/vX.Y.Z_implementation_verification.md` to exist, be non-trivial, and
carry an explicit PASS or PASS_WITH_GAPS verdict. A release report authored by
the implementer certifies nothing.

Commands:
  check     - verify the gate only (exit 0 = release may proceed)
  package   - verify the gate, then build plugin_Parallax_v<version>.zip via
              `git archive` plus SHA256SUMS.v<version> in --output-dir

This is a maintainer script, not a public plugin command.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERDICTS_OK = ("PASS_WITH_GAPS", "PASS")
VERDICTS_ALL = ("PASS_WITH_GAPS", "PASS", "FAIL", "BLOCKED")


def fail(message: str) -> int:
    print(json.dumps({"release_gate": "refused", "error": message}, sort_keys=True))
    return 2


def plugin_version(repo: Path) -> str:
    manifest = json.loads((repo / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
    version = str(manifest.get("version", ""))
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"plugin.json version {version!r} is not X.Y.Z")
    return version


def find_review(repo: Path, version: str, reviews_dir: Path | None) -> Path:
    candidates = [reviews_dir] if reviews_dir else [repo / "REVIEWS", repo.parent / "REVIEWS"]
    for directory in candidates:
        if directory and directory.is_dir():
            return directory / f"v{version}_implementation_verification.md"
    return (reviews_dir or repo / "REVIEWS") / f"v{version}_implementation_verification.md"


def gate(repo: Path, version: str, reviews_dir: Path | None) -> tuple[bool, str, Path]:
    review = find_review(repo, version, reviews_dir)
    if not review.exists():
        return False, (f"no durable verifier verdict: {review} does not exist. "
                       "An implementer-authored release report does not certify a release "
                       "(IMPLEMENTATION_VERIFICATION_PROTOCOL.md §5); write the independent "
                       "verification file first."), review
    text = review.read_text(encoding="utf-8")
    if len(text.strip()) < 200:
        return False, f"verifier verdict {review} is too short to be a real verification report", review
    found = next((v for v in VERDICTS_ALL if re.search(rf"\b{v}\b", text)), None)
    if found is None:
        return False, (f"verifier verdict {review} carries no explicit verdict "
                       f"(expected one of {', '.join(VERDICTS_ALL)})"), review
    if found not in VERDICTS_OK:
        return False, f"verifier verdict in {review} is {found}; a {found} release cannot be packaged", review
    return True, found, review


def package(repo: Path, version: str, output_dir: Path) -> dict[str, str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    zip_path = output_dir / f"plugin_Parallax_v{version}.zip"
    proc = subprocess.run(["git", "-C", str(repo), "archive", "--format=zip",
                           f"--output={zip_path}", "HEAD"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"git archive failed: {proc.stderr.strip()}")
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    sums = output_dir / f"SHA256SUMS.v{version}"
    sums.write_text(f"{digest}  {zip_path.name}\n", encoding="utf-8")
    return {"zip": str(zip_path), "sha256sums": str(sums), "sha256": digest}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    for name in ("check", "package"):
        p = sub.add_parser(name)
        p.add_argument("--repo", default=str(ROOT))
        p.add_argument("--version", default=None, help="defaults to .claude-plugin/plugin.json version")
        p.add_argument("--reviews-dir", default=None,
                       help="directory holding v<version>_implementation_verification.md "
                            "(default: <repo>/REVIEWS then <repo>/../REVIEWS)")
        if name == "package":
            p.add_argument("--output-dir", default=None, help="default: parent of --repo")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    try:
        version = args.version or plugin_version(repo)
        ok, detail, review = gate(repo, version, Path(args.reviews_dir).resolve() if args.reviews_dir else None)
        if not ok:
            return fail(detail)
        result = {"release_gate": "ok", "version": version, "verdict": detail, "review": str(review)}
        if args.command == "package":
            output_dir = Path(args.output_dir).resolve() if args.output_dir else repo.parent
            result.update(package(repo, version, output_dir))
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        return fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
