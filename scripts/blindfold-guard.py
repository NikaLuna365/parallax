#!/usr/bin/env python3
"""Parallax blindfold guard (v0.37 P0.1) — deterministic cross-track isolation check.

Blindness is the core of the Parallax method: the test-writer must never see the
implementation, and the blind-coder must never see the tests. In brownfield / monorepo
runs that wall collapses when the wrong TRACKED files (implementation source, compiled
`dist/` output, fixtures that encode expected values) are present inside a track's
worktree — at which point Parallax silently degrades into "the same model writes tests
after seeing the code". This guard makes the wall mechanical instead of honour-based:
it inspects the *tracked* files of a track's worktree and fails closed when opposite-side
or compiled artifacts are present. `/parallax:run` runs it BEFORE dispatching each blind
track and again BEFORE accepting that track's done-gate, per wave (not once at setup).

Sides:
  --side test  the test-writer worktree. MUST NOT contain implementation source or
               compiled build output for the slice.
  --side code  the blind-coder worktree. MUST NOT contain test files.

Classification is deterministic. The defaults below match common test / implementation /
compiled conventions; --test-glob / --impl-glob / --compiled-glob EXTEND them for a
specific repo, and --allow-glob whitelists public fixtures the frozen spec explicitly
permits (e.g. a named baseline fixture). Only TRACKED files count (`git ls-files`): an
untracked scratch file is not contamination, a committed one is.

Exit: 0 clean, 2 contamination (caller must park / fail closed — never "continue anyway"),
3 bad input (treated as fail-closed by callers).
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

# --- deterministic default classification (POSIX paths) ---
_TEST_DIR = re.compile(r"(^|/)(tests?|__tests__|specs?|e2e|__mocks__)(/|$)", re.I)
_TEST_BASE = re.compile(r"(^|[._-])(test|tests|spec|specs)([._-][^/]*)?$", re.I)
_COMPILED_DIR = re.compile(
    r"(^|/)(dist|build|out|bin|obj|coverage|\.next|\.nuxt|\.svelte-kit|target|node_modules|__pycache__)(/|$)",
    re.I,
)
_SRC_EXT = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".rs", ".java",
    ".rb", ".php", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".cs", ".kt", ".kts",
    ".swift", ".scala", ".m", ".mm", ".vue", ".svelte", ".html", ".htm", ".css",
    ".scss", ".sass", ".less", ".sql",
}


def _is_test(path, extra):
    base = os.path.basename(path)
    stem = base.rsplit(".", 1)[0] if "." in base else base
    if _TEST_DIR.search(path):
        return True
    if _TEST_BASE.search(stem):
        return True
    return any(fnmatch.fnmatch(path, g) for g in extra)


def _is_compiled(path, extra):
    if _COMPILED_DIR.search(path):
        return True
    return any(fnmatch.fnmatch(path, g) for g in extra)


def _is_impl(path, extra):
    # an implementation/source/markup file (NOT a test) — by extension or by explicit glob
    ext = os.path.splitext(path)[1].lower()
    if ext in _SRC_EXT:
        return True
    return any(fnmatch.fnmatch(path, g) for g in extra)


def _tracked(worktree):
    p = subprocess.run(
        ["git", "-C", worktree, "ls-files"], capture_output=True, text=True
    )
    if p.returncode != 0:
        return None, p.stderr.strip()
    return [l for l in p.stdout.splitlines() if l.strip()], None


def guard(worktree, side, test_glob, impl_glob, compiled_glob, allow_glob):
    files, err = _tracked(worktree)
    if files is None:
        return 3, {"error": f"git ls-files failed in {worktree!r}: {err}"}
    allowed = lambda f: any(fnmatch.fnmatch(f, g) for g in allow_glob)
    offending = []
    for f in files:
        if allowed(f):
            continue
        is_test = _is_test(f, test_glob)
        if side == "test":
            # the test worktree must not see implementation source or compiled output
            if _is_compiled(f, compiled_glob):
                offending.append({"path": f, "why": "compiled-build-output-visible-to-test-writer"})
            elif (not is_test) and _is_impl(f, impl_glob):
                offending.append({"path": f, "why": "implementation-source-visible-to-test-writer"})
        else:  # side == "code"
            if is_test:
                offending.append({"path": f, "why": "test-file-visible-to-blind-coder"})
    if offending:
        return 2, {"verdict": "contaminated", "side": side, "offending": offending}
    return 0, {"verdict": "clean", "side": side, "tracked": len(files)}


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37 blindfold isolation guard.")
    ap.add_argument("--worktree", default=".", help="track worktree to inspect (default: cwd)")
    ap.add_argument("--side", required=True, choices=["test", "code"],
                    help="test = test-writer worktree; code = blind-coder worktree")
    ap.add_argument("--slug", default=None)
    ap.add_argument("--test-glob", action="append", default=[], help="extra test-path globs")
    ap.add_argument("--impl-glob", action="append", default=[], help="extra implementation-path globs")
    ap.add_argument("--compiled-glob", action="append", default=[], help="extra compiled-output globs")
    ap.add_argument("--allow-glob", action="append", default=[],
                    help="public fixture globs the frozen spec explicitly permits on the test side")
    a = ap.parse_args(argv)
    code, detail = guard(a.worktree, a.side, a.test_glob, a.impl_glob, a.compiled_glob, a.allow_glob)
    detail["slug"] = a.slug
    print(json.dumps(detail))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
