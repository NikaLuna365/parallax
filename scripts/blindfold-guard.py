#!/usr/bin/env python3
"""Parallax blindfold guard (v0.37 P0.1; slice-scoped monorepo mode v0.37.3 F1) —
deterministic cross-track isolation check.

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

Slice-scoped monorepo mode (v0.37.3 F1, `--scope-manifest <path>`): the whole-tree sweep
above false-positives in a pnpm/monorepo workspace, where the test worktree legitimately
needs a SIBLING package's source or `dist/` present just to resolve cross-package imports
(`@scope/shared`) — to the static heuristics that looks identical to a leaked
implementation. The scope manifest (schema `assets/blindfold-scope.schema.json`, derived
per slice by /parallax:run from slices.lock + validation.md's "Monorepo dependency roots")
narrows the guarantee to what actually matters for THIS slice:

  * `protected_impl_paths` — the slice's OWN new/changed implementation files. ALWAYS
    contamination on the test side when tracked, checked before every allowlist; no glob
    can mask them.
  * `protected_test_paths` — the slice's OWN test files. ALWAYS contamination on the code
    side when tracked, in addition to the normal test heuristics.
  * `dependency_allow_globs` — sibling-package roots the test side may see for import
    resolution only (e.g. `packages/shared/src/**`, `packages/shared/dist/**`). They must
    be package-specific — mechanically, the schema requires the FIRST path segment to be a
    fully literal directory name (no `*`/`?`/`[…]` anywhere in it, not dot-leading), which
    makes every whole-tree-equivalent form (`**`, `**/*`, `*`, `*.*`, `?*`, `[a-z]*`,
    `./**`, `/**`, …) unrepresentable while still allowing `packages/*/dist/**`. Monorepo
    mode is therefore never a blanket `--allow-glob '**'` bypass.

In slice-scoped mode the TEST side's blindness guarantee is deliberately re-anchored: the
existing BASE tree is visible by design (a monorepo test worktree cannot resolve imports
without it), so the generic "any source extension is a leak" heuristic is suspended there
and the implementation-leak check narrows to exactly `protected_impl_paths` — the files
this slice is actually creating/changing, which are the only implementation the
test-writer could cheat from. Compiled build output is still rejected wholesale unless a
`dependency_allow_globs` root explicitly covers it (a sibling's committed `dist/` needed
for resolution) — the slice's own package `dist/` therefore still fails closed. The CODE
side keeps the full test heuristics (its base tree was already test-free after the
blindfold `git rm`) plus `protected_test_paths`.

Without `--scope-manifest` the original strict whole-tree mode runs unchanged (simple
repos). A malformed/mismatched manifest is bad input (exit 3) — never a silent fallback
to a weaker or stronger mode than the caller asked for.

Two v0.37.3 default fixes apply in BOTH modes: `.parallax/**` is the plugin's own shared,
always-present contract surface (spec.md / slices / validation / reviews / evidence —
deliberately visible to both tracks), so it is never classified as test/impl/compiled
contamination — previously the bare `spec` stem made every `.parallax/<slug>/spec.md`
count as a test file. And `bin/` is no longer treated as compiled build output by default
(many repos keep ordinary tracked scripts there); when a repo's `bin/` genuinely IS
generated output, pass `--compiled-glob 'bin/**'` explicitly.

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
# v0.37.3 F1 — "bin" removed from the default alternation: a tracked bin/ usually holds
# ordinary scripts, not build output. Repos where bin/ IS generated pass --compiled-glob 'bin/**'.
_COMPILED_DIR = re.compile(
    r"(^|/)(dist|build|out|obj|coverage|\.next|\.nuxt|\.svelte-kit|target|node_modules|__pycache__)(/|$)",
    re.I,
)
# v0.37.3 F1 — the plugin's own shared, always-present contract surface: .parallax/** is
# deliberately visible to BOTH blind tracks (frozen spec/slices/validation, reviews,
# evidence), so nothing under it is ever test/impl/compiled contamination. This also stops
# the bare "spec" stem heuristic from classifying .parallax/<slug>/spec.md as a test file.
_SHARED_DIR = re.compile(r"(^|/)\.parallax(/|$)")
_SRC_EXT = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".rs", ".java",
    ".rb", ".php", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".cs", ".kt", ".kts",
    ".swift", ".scala", ".m", ".mm", ".vue", ".svelte", ".html", ".htm", ".css",
    ".scss", ".sass", ".less", ".sql",
}


def _is_shared(path):
    return bool(_SHARED_DIR.search(path))


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


_SCOPE_SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "blindfold-scope.schema.json",
)


def load_scope(path, expect_slug):
    """Load + schema-validate the per-slice monorepo scope manifest (v0.37.3 F1).
    Fail closed on ANY problem — a caller that asked for slice-scoped mode and handed a
    malformed manifest must get exit 3, never a silent fallback to a different mode."""
    try:
        import jsonschema
    except ImportError as exc:
        raise ValueError(f"jsonschema is required for --scope-manifest; refusing an unvalidated scope: {exc}")
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"cannot read scope manifest {path!r}: {exc}")
    try:
        schema = json.load(open(_SCOPE_SCHEMA_PATH, encoding="utf-8"))
        jsonschema.validate(doc, schema)
    except Exception as exc:
        raise ValueError(f"scope manifest {path!r} is not schema-valid: {exc}")
    if expect_slug is not None and doc["slug"] != expect_slug:
        raise ValueError(f"scope manifest slug {doc['slug']!r} != --slug {expect_slug!r}")
    return doc


def _tree_files(repo, ref):
    """Tracked file set at a git ref (for --base-ref new-vs-base detection). None on failure."""
    p = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", ref],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return {l for l in p.stdout.splitlines() if l}


def guard(worktree, side, test_glob, impl_glob, compiled_glob, allow_glob, scope=None, new_impl_paths=None):
    files, err = _tracked(worktree)
    if files is None:
        return 3, {"error": f"git ls-files failed in {worktree!r}: {err}"}
    protected_impl = set(scope["protected_impl_paths"]) if scope else set()
    protected_test = set(scope["protected_test_paths"]) if scope else set()
    dep_globs = list(scope["dependency_allow_globs"]) if scope else []
    # v0.39 §5.4 — files created SINCE the slice's base (fork point). In scope mode, a NEW impl
    # file is the slice's OWN work even if it sits under a broad dependency_allow_globs root, so it
    # must fail closed on the test side even though the base tree under that root is visible.
    new_impl = set(new_impl_paths) if new_impl_paths else set()
    allowed = lambda f: any(fnmatch.fnmatch(f, g) for g in allow_glob)
    dep_allowed = lambda f: any(fnmatch.fnmatch(f, g) for g in dep_globs)
    offending = []
    for f in files:
        # the plugin's own shared contract surface is never contamination (v0.37.3 F1)
        if _is_shared(f):
            continue
        is_test = _is_test(f, test_glob)
        if side == "test":
            # the slice's OWN new/changed implementation ALWAYS fails closed on the test
            # side — checked before --allow-glob and before dependency_allow_globs, so no
            # allowlist (however broad) can mask a protected leak (v0.37.3 F1).
            if f in protected_impl:
                offending.append({"path": f, "why": "implementation-source-visible-to-test-writer",
                                  "protected": True})
                continue
            # v0.39 §5.4 (guard:196 hardening) — a NEW-since-base implementation file the manifest
            # DID NOT list is still the slice's own new work; in scope mode it would otherwise be
            # masked by a broad dependency_allow_globs (e.g. src/packages/shared/**). Check it
            # BEFORE the allow/dep-glob short-circuit so no allowlist can hide it (fail closed).
            if scope is not None and f in new_impl and (not is_test) and _is_impl(f, impl_glob) \
               and not _is_compiled(f, compiled_glob):
                offending.append({"path": f, "why": "new-implementation-source-visible-to-test-writer-absent-from-protected",
                                  "new_since_base": True})
                continue
            if allowed(f) or dep_allowed(f):
                continue
            # the test worktree must not see implementation source or compiled output
            if _is_compiled(f, compiled_glob):
                offending.append({"path": f, "why": "compiled-build-output-visible-to-test-writer"})
            elif scope is None and (not is_test) and _is_impl(f, impl_glob):
                # strict mode only: any tracked source file is a leak. In slice-scoped
                # (monorepo) mode the existing base tree is visible BY DESIGN (import
                # resolution needs it), so the implementation-leak check narrows to the
                # protected_impl_paths above — the slice's own new/changed files.
                offending.append({"path": f, "why": "implementation-source-visible-to-test-writer"})
        else:  # side == "code"
            # the slice's OWN test files ALWAYS fail closed on the code side (v0.37.3 F1);
            # dependency_allow_globs are a TEST-side resolution aid and never apply here.
            if f in protected_test:
                offending.append({"path": f, "why": "test-file-visible-to-blind-coder",
                                  "protected": True})
                continue
            if allowed(f):
                continue
            if is_test:
                offending.append({"path": f, "why": "test-file-visible-to-blind-coder"})
    if offending:
        return 2, {"verdict": "contaminated", "side": side, "offending": offending}
    return 0, {"verdict": "clean", "side": side, "tracked": len(files)}


def assert_pathspec_match(a):
    """v0.39 §5.2 D1 — fail closed on a zero-match blindfold pathspec. The canonical blindfold
    `git rm '**/*.test.ts'` silently NO-OPS on a src/-prefixed pnpm workspace (parallax-errors.md:160):
    the pathspec matches zero files, so the tree is never blindfolded and no leak is flagged (there
    is nothing to flag — the tests were simply never removed). This asserts the test-side pathspec
    matches a NON-EMPTY set of files on the source ref, so a wrong monorepo pathspec cannot let the
    blindfold no-op silently. A slice that genuinely has no test files records that with --allow-no-tests."""
    if not a.pathspec:
        print(json.dumps({"error": "assert-pathspec-match requires at least one --pathspec"}))
        return 3
    repo = a.repo or a.worktree
    # `git ls-files` (unlike `git ls-tree`) honors :(glob) pathspec magic — the SAME matching the
    # blindfold `git rm -- "${TEST_PATHSPECS[@]}"` uses on the worktree — so this asserts exactly what
    # the rm would remove. Run in the worktree BEFORE the rm.
    cmd = ["git", "-C", repo, "ls-files", "--", *a.pathspec]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print(json.dumps({"error": f"git ls-files failed in {repo!r}: {p.stderr.strip()}"}))
        return 3
    matched = [l for l in p.stdout.splitlines() if l]
    if not matched:
        if a.allow_no_tests:
            print(json.dumps({"verdict": "no-tests-ok", "pathspec": a.pathspec,
                              "note": "zero match ALLOWED — slice explicitly recorded as test-less (--allow-no-tests)"}))
            return 0
        print(json.dumps({"verdict": "zero-match", "pathspec": a.pathspec,
                          "error": "blindfold pathspec matches ZERO files — a `git rm` here would "
                                   "silently no-op and leave the tree UN-BLINDFOLDED (v0.39 §5.2 D1). "
                                   "Fix the monorepo pathspec (e.g. src/ prefix) or pass --allow-no-tests "
                                   "if the slice genuinely has no tests."}))
        return 2
    print(json.dumps({"verdict": "matched", "pathspec": a.pathspec, "count": len(matched)}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37 / v0.37.3 / v0.39 blindfold isolation guard.")
    ap.add_argument("--worktree", default=".", help="track worktree to inspect (default: cwd)")
    ap.add_argument("--side", default=None, choices=["test", "code"],
                    help="test = test-writer worktree; code = blind-coder worktree (required unless --assert-pathspec-match)")
    ap.add_argument("--slug", default=None)
    ap.add_argument("--test-glob", action="append", default=[], help="extra test-path globs")
    ap.add_argument("--impl-glob", action="append", default=[], help="extra implementation-path globs")
    ap.add_argument("--compiled-glob", action="append", default=[],
                    help="extra compiled-output globs (e.g. 'bin/**' when a repo's bin/ IS generated output)")
    ap.add_argument("--allow-glob", action="append", default=[],
                    help="public fixture globs the frozen spec explicitly permits on the test side")
    ap.add_argument("--scope-manifest", default=None,
                    help="v0.37.3 F1: per-slice monorepo scope manifest "
                         "(assets/blindfold-scope.schema.json). protected_impl_paths / "
                         "protected_test_paths always fail closed on the opposite track; "
                         "dependency_allow_globs are visible to the test side for import "
                         "resolution. Omit for the original strict whole-tree mode.")
    ap.add_argument("--base-ref", default=None,
                    help="v0.39 §5.4: the slice's base/fork ref. In scope mode, a NEW-since-base impl "
                         "file absent from protected_impl_paths fails closed on the test side even under "
                         "a broad dependency_allow_globs (closes the guard:196 hole).")
    # v0.39 §5.2 D1 — zero-match blindfold pathspec assertion (no --side needed).
    ap.add_argument("--assert-pathspec-match", dest="assert_pathspec_match", action="store_true",
                    help="assert the given --pathspec matches a NON-EMPTY set on --ref (fail closed on a "
                         "silent zero-match blindfold no-op); does not scan a worktree")
    ap.add_argument("--repo", default=None, help="repo for --assert-pathspec-match (default: --worktree)")
    ap.add_argument("--ref", default="HEAD", help="source ref for --assert-pathspec-match (default: HEAD)")
    ap.add_argument("--pathspec", action="append", default=[], help="git pathspec(s) for --assert-pathspec-match")
    ap.add_argument("--allow-no-tests", dest="allow_no_tests", action="store_true",
                    help="permit a zero-match (slice genuinely has no test files)")
    a = ap.parse_args(argv)

    if a.assert_pathspec_match:
        return assert_pathspec_match(a)

    if a.side is None:
        print(json.dumps({"error": "--side is required (test|code) unless --assert-pathspec-match"}))
        return 3
    scope = None
    if a.scope_manifest:
        try:
            scope = load_scope(a.scope_manifest, a.slug)
        except ValueError as exc:
            print(json.dumps({"error": str(exc), "slug": a.slug}))
            return 3
    new_impl_paths = None
    if a.base_ref and scope is not None:
        cur = _tree_files(a.worktree, "HEAD")
        base = _tree_files(a.worktree, a.base_ref)
        if cur is None or base is None:
            print(json.dumps({"error": f"--base-ref set but cannot read HEAD/{a.base_ref!r} in {a.worktree!r}",
                              "slug": a.slug}))
            return 3
        new_impl_paths = cur - base
    code, detail = guard(a.worktree, a.side, a.test_glob, a.impl_glob, a.compiled_glob,
                         a.allow_glob, scope, new_impl_paths)
    detail["slug"] = a.slug
    detail["mode"] = "slice-scoped" if scope else "strict"
    print(json.dumps(detail))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
