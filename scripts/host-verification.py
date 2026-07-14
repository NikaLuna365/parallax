#!/usr/bin/env python3
"""Local Claude/Codex checks; never performs inference or reports quota health."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path


def _command_status(command: str, args: list[str], timeout: float = 15.0) -> str:
    if shutil.which(command) is None:
        return "missing"
    try:
        result = subprocess.run([command, *args], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return "failed"
    return "ok" if result.returncode == 0 else "failed"


def _configured_signal(registry_path: Path | None, names: tuple[str, ...]) -> str:
    if not registry_path or not registry_path.exists():
        return "documented-but-not-configured"
    try:
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from provider_runtime import load_registry
        registry, _ = load_registry(registry_path.parent.parent, registry_path)
    except Exception:
        return "invalid-registry"
    for name in names:
        provider = registry.get("providers", {}).get(name, {})
        if provider.get("live_signal_path") or provider.get("live_signal_command"):
            return "configured"
    return "documented-but-not-configured"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", default=None)
    parser.add_argument("--skip-doctor", action="store_true")
    args = parser.parse_args(argv)
    registry = Path(args.registry).resolve() if args.registry else None
    claude = {
        "cli_available": shutil.which("claude") is not None,
        "version_check": _command_status("claude", ["--version"]),
        "rate_limits_statusline_seam": _configured_signal(registry, ("claude", "claude-code")),
        "auth_evidence": "not-probed",
        "quota_evidence": "unknown",
    }
    codex = {
        "cli_available": shutil.which("codex") is not None,
        "version_check": _command_status("codex", ["--version"]),
        "usage_status_app_server_seam": _configured_signal(registry, ("codex",)),
        "auth_evidence": "not-probed",
        "quota_evidence": "unknown",
        "doctor": {"status": "not-run" if args.skip_doctor else _command_status("codex", ["doctor"]),
                   "role": "diagnostic-only"},
    }
    result = {
        "schema_version": "parallax-host-verification-v1",
        "hosts": {"claude-code": claude, "codex": codex},
        "host_smoke": "host_smoke_not_safe",
        "limitations": [
            "version and doctor results are installation/auth/runtime diagnostics only",
            "no inference was executed; quota/reset evidence remains unknown",
            "Claude rate_limits and Codex usage/status/app-server values require a host-emitted signal",
        ],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
