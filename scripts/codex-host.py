#!/usr/bin/env python3
"""Codex-hosted Parallax seam.

The host accepts the same frozen artifacts and worker request used by the
Claude-host path.  It does not emulate Claude's Task tool.  A request with a
real worktree/visibility manifest is dispatched through provider_runtime.py;
an invocation without those artifacts parks with host_capability_missing.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from provider_runtime import ROLE_ALIASES, ROLE_BLINDFOLD_SIDES, REVIEWER_ROLES, dispatch, load_registry


def _json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--request", required=True, help="JSON worker request from the frozen run artifacts")
    ap.add_argument("--registry", required=True, help=".parallax/providers.toml")
    ap.add_argument("--host", default="codex", choices=["codex", "shell"])
    ap.add_argument("--artifact-dir", default=None, help="directory where host-run.json is written")
    args = ap.parse_args(argv)
    request = _json(Path(args.request))
    role_key = ROLE_ALIASES.get(request.get("role"), request.get("role"))
    required = ["role", "slice_id", "worktree", "expected_branch", "spec_path", "validation_path", "visibility_manifest", "prompt"]
    # The blindness role contract is part of the host's required-key list: a
    # request that would open the wall is NOT a valid host request.
    if role_key in ROLE_BLINDFOLD_SIDES:
        required += ["side", "slug"]
    missing = [key for key in required if key not in request]
    missing += [key for key in ("spec_path", "validation_path")
                if key in request and not Path(request[key]).exists()]
    if missing:
        blindfold_incomplete = role_key in ROLE_BLINDFOLD_SIDES and any(key in ("side", "slug") for key in missing)
        result = {"status": "parked",
                  "error_class": "blindfold-request-incomplete" if blindfold_incomplete else "host_capability_missing",
                  "missing_artifacts": missing, "host": args.host}
        print(json.dumps(result, indent=2, sort_keys=True))
        return 2
    try:
        registry, _ = load_registry(Path(request.get("repo", ".")).resolve(), Path(args.registry).resolve())
        result = dispatch(request, registry, args.host)
    except ValueError as exc:
        unsafe = any(marker in str(exc) for marker in
                     ("effective provider", "Aider transport", "unsafe-provider-chain", "reviewer chain"))
        error_class = "unsafe-provider-chain" if unsafe else "host_capability_missing"
        result = {"status": "parked", "error_class": error_class, "host": args.host}
    except OSError:
        result = {"status": "parked", "error_class": "host_capability_missing", "host": args.host}
    except Exception:
        # A provider/runtime failure is not turned into a host capability claim.
        result = {"status": "parked", "error_class": "provider-runtime-error", "host": args.host}
    if args.artifact_dir:
        out = Path(args.artifact_dir) / "host-run.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"schema_version": "parallax-host-run-v1", "host": args.host,
                                   "request": str(Path(args.request).resolve()), "result": result},
                                  indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get("review_verdict") == "concerns":
        return 2
    if role_key in REVIEWER_ROLES:
        # A reviewer succeeds only with an explicit schema-valid verdict and a
        # raw receipt; a null verdict or empty artifacts is a provider failure.
        return 0 if (result.get("status") == "no_change"
                     and result.get("review_verdict") == "pass"
                     and result.get("artifacts")) else 2
    return 0 if result.get("status") in {"committed", "no_change"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
