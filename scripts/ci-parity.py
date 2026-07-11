#!/usr/bin/env python3
"""Parallax CI/lint parity checker (v0.39 §5.3) — local-green must == CI-green for a declared check.

The live divergence (parallax-errors.md:88): CI runs `biome` format-only over the WHOLE tree, while
the local validation contract runs the linter PER-FILE — so a slice green locally can be red in CI.
A green that CI later rejects is a false local-green for shipping purposes.

The validation contract may declare, per check, a `ci_equivalent` command (the whole-tree form CI
actually runs). The arbiter runs BOTH the local form and the CI-equivalent form through this helper;
if the local form passes but the CI-equivalent form FAILS, the slice is NOT green — the divergence is
the exact defect this guards. Both commands run via the shell in --cwd.

Exit: 0 both pass (or no --ci given and local passes); 1 the LOCAL command failed (ordinary red —
route it the normal way); 2 CI-DIVERGENCE — local passed but the CI-equivalent form failed (NOT green);
3 bad input.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys


def _run(cmd: str, cwd: str):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Parallax v0.39 CI/lint parity checker.")
    ap.add_argument("--local", required=True, help="the local (per-file) validation command")
    ap.add_argument("--ci", default=None, help="the CI-equivalent (whole-tree) command the repo's CI runs")
    ap.add_argument("--cwd", default=".", help="working directory to run the commands in")
    a = ap.parse_args(argv)

    lrc, lout = _run(a.local, a.cwd)
    if lrc != 0:
        print(json.dumps({"verdict": "local-red", "local_rc": lrc,
                          "note": "local check failed — ordinary RED, route to the fault side"}))
        return 1
    if not a.ci:
        print(json.dumps({"verdict": "local-green", "ci": None,
                          "note": "no CI-equivalent declared for this check"}))
        return 0
    crc, cout = _run(a.ci, a.cwd)
    if crc != 0:
        print(json.dumps({"verdict": "ci-divergence", "local_rc": 0, "ci_rc": crc,
                          "error": "local check PASSED but the declared CI-equivalent (whole-tree) form "
                                   "FAILED — local-green != CI-green; the slice is NOT green (v0.39 §5.3). "
                                   "Fix so the CI form passes, or reconcile the contract.",
                          "ci_output_tail": cout[-800:]}))
        return 2
    print(json.dumps({"verdict": "parity", "local_rc": 0, "ci_rc": 0,
                      "note": "local-green AND CI-equivalent green"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
