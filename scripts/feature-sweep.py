#!/usr/bin/env python3
"""Parallax whole-feature invariant sweep (v0.37 P0.3).

Per-slice green can still miss whole-feature defects: a PII/trust field that leaks once
the slices are assembled, a money/pricing rule violated across files, a shared entity that
serializes inconsistently, a dead field/seam, a shared-interface change that breaks a
sibling, or an I/O-heavy slice whose tests are mock-only. This sweep runs ONCE over the
integrated tree, just before final completion, against the concrete invariant classes the
/parallax:spec prohibition-reconciliation substep declared in
`.parallax/<slug>/invariants.json`.

It is deliberately NOT a broad style/architecture review: it only checks the declared,
machine-checkable invariants. Three classes:
  * forbidden_patterns  — a regex that must not appear in shipped code under given globs;
  * required_consumers  — a shared field present in a producer but in no consumer (dead);
  * mock_only_slices    — an I/O-heavy slice with neither an integration check nor a stamp.

Exit: 0 clean, 2 violation (block completion), 3 bad input (missing/invalid manifest =>
fail-closed: an absent manifest cannot silently pass a feature).
"""
import argparse
import fnmatch
import json
import os
import re
import sys

_SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "feature-invariants.schema.json")
_SKIP_DIRS = {".git", ".parallax", "node_modules", "dist", "build", "out", "coverage",
              "__pycache__", ".next", ".nuxt", ".svelte-kit", "target"}


def _walk(root):
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in _SKIP_DIRS]
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            yield rel, full


def _matches(rel, globs):
    return any(fnmatch.fnmatch(rel, g) for g in globs)


def _read(full):
    try:
        return open(full, "r", errors="replace").read()
    except OSError:
        return ""


def _validate_manifest(man):
    try:
        import jsonschema
    except ImportError:
        return None  # structural checks below still apply
    try:
        jsonschema.validate(man, json.load(open(_SCHEMA)))
        return None
    except Exception as e:
        return f"manifest-invalid: {getattr(e, 'message', e)}"


def sweep(repo, slug, manifest_path=None):
    mp = manifest_path or os.path.join(repo, ".parallax", slug, "invariants.json")
    if not os.path.exists(mp):
        return 3, {"manifest": f"missing {mp} (fail-closed: declare invariants at spec freeze)"}
    try:
        man = json.load(open(mp))
    except Exception as e:
        return 3, {"manifest": f"bad json: {e}"}
    verr = _validate_manifest(man)
    if verr:
        return 3, {"manifest": verr}
    if man.get("slug") not in (slug, None):
        return 3, {"manifest": f"slug={man.get('slug')!r} != {slug!r}"}

    files = list(_walk(repo))
    violations = []

    # 1) forbidden patterns
    for fp in man.get("forbidden_patterns", []):
        rx = re.compile(fp["pattern"])
        for rel, full in files:
            if not _matches(rel, fp["paths"]):
                continue
            if rx.search(_read(full)):
                violations.append({"class": "forbidden_pattern", "id": fp["id"],
                                   "path": rel, "reason": fp["reason"]})

    # 2) required consumers (a shared field with no live consumer is dead)
    for rc in man.get("required_consumers", []):
        rx = re.compile(rc["field"])
        in_producer = any(_matches(rel, rc["producer_paths"]) and rx.search(_read(full))
                          for rel, full in files)
        if not in_producer:
            continue  # field not introduced => nothing to require
        in_consumer = any(_matches(rel, rc["consumer_paths"]) and rx.search(_read(full))
                          for rel, full in files)
        if not in_consumer:
            violations.append({"class": "dead_shared_field", "id": rc["id"],
                               "field": rc["field"], "reason": rc["reason"]})

    # 3) mock-only I/O slices
    rels = [rel for rel, _ in files]
    for ms in man.get("mock_only_slices", []):
        has_integration = any(_matches(rel, ms["integration_glob"]) for rel in rels)
        has_stamp = os.path.exists(os.path.join(repo, ms["stamp"]))
        if not has_integration and not has_stamp:
            violations.append({"class": "mock_only_io", "slice_id": ms["slice_id"],
                               "reason": "no integration/contract check and no explicit mock-only stamp"})

    if violations:
        return 2, {"verdict": "violations", "slug": slug, "violations": violations}
    return 0, {"verdict": "clean", "slug": slug,
               "checked": {"forbidden": len(man.get("forbidden_patterns", [])),
                           "consumers": len(man.get("required_consumers", [])),
                           "mock_only": len(man.get("mock_only_slices", []))}}


def main(argv):
    ap = argparse.ArgumentParser(description="Parallax v0.37 whole-feature invariant sweep.")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--slug", required=True)
    ap.add_argument("--manifest", default=None, help="override path to invariants.json")
    a = ap.parse_args(argv)
    code, detail = sweep(a.repo, a.slug, a.manifest)
    print(json.dumps(detail))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
