#!/usr/bin/env python3
"""Read-only structured reviewer transport.

This is deliberately separate from the worker runtime. A reviewer receives a
serialized view of an already assembled tree and returns one review-round JSON
object. It never starts Aider, a shell, git, or a model-owned file writer.
The runtime validates the full review schema and owns the raw receipt write.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
ROUND_SCHEMA = ROOT / "assets" / "codex" / "review-round.schema.json"
MAX_CONTEXT_BYTES = 8 * 1024 * 1024


class ReviewError(RuntimeError):
    def __init__(self, error_class: str, message: str = ""):
        super().__init__(message or error_class)
        self.error_class = error_class


def _json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReviewError("invalid-request") from exc


def _validate(doc: Any, schema_path: Path) -> None:
    try:
        import jsonschema
    except ImportError as exc:
        raise ReviewError("schema-validator-missing") from exc
    try:
        jsonschema.validate(doc, _json(schema_path))
    except Exception as exc:
        raise ReviewError("schema-invalid") from exc


def _dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def _secret(repo: Path, key_env: str) -> str | None:
    if os.environ.get(key_env):
        return os.environ[key_env]
    for path in (repo / ".parallax" / ".env", repo / ".parallax" / "zai.env",
                 Path.home() / ".config" / "parallax" / "providers.env"):
        value = _dotenv(path).get(key_env)
        if value:
            return value
    return None


def _safe_context_path(repo: Path, value: str) -> Path:
    path = Path(value)
    if not path.is_absolute() and ".." in path.parts:
        raise ReviewError("unsafe-context-path")
    resolved = path.resolve() if path.is_absolute() else (repo / path).resolve()
    try:
        resolved.relative_to(repo.resolve())
    except ValueError as exc:
        raise ReviewError("unsafe-context-path") from exc
    if not resolved.is_file():
        raise ReviewError("missing-context-file")
    return resolved


def _context(request: dict[str, Any], repo: Path) -> str:
    items = request.get("context_files", [])
    if not isinstance(items, list):
        raise ReviewError("invalid-context")
    total = 0
    blocks: list[str] = []
    for item in items:
        if isinstance(item, str):
            label, value = item, item
        elif isinstance(item, dict) and isinstance(item.get("path"), str):
            label, value = str(item.get("label") or item["path"]), item["path"]
        else:
            raise ReviewError("invalid-context")
        path = _safe_context_path(repo, value)
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise ReviewError("unreadable-context-file") from exc
        total += len(content.encode("utf-8"))
        if total > int(request.get("max_context_bytes", MAX_CONTEXT_BYTES)):
            raise ReviewError("context-too-large")
        blocks.append(f"\n===== {label} ({value}) =====\n{content}")
    return "".join(blocks)


def _snapshot(repo: Path, excluded: Path) -> dict[str, str]:
    """Hash regular candidate files to detect an unexpected local mutation."""
    result: dict[str, str] = {}
    excluded = excluded.resolve()
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            path = (Path(root) / name).resolve()
            if path == excluded or path.is_symlink():
                continue
            try:
                result[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            except OSError as exc:
                raise ReviewError("worktree-snapshot-failed") from exc
    return result


def _assert_unchanged(repo: Path, before: dict[str, str], excluded: Path) -> None:
    if before != _snapshot(repo, excluded):
        raise ReviewError("reviewer-worktree-mutated")


def _response_content(payload: Any) -> str:
    try:
        content = payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ReviewError("malformed-provider-response") from exc
    if not isinstance(content, str) or not content.strip():
        raise ReviewError("empty-provider-response")
    return content


def _atomic_write(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def run_review(request: dict[str, Any], registry: dict[str, Any], provider_name: str) -> dict[str, Any]:
    provider = registry.get("providers", {}).get(provider_name)
    if not isinstance(provider, dict):
        raise ReviewError("unknown-provider")
    if provider.get("transport") != "review-api":
        raise ReviewError("reviewer-transport-required")
    if provider.get("kind") not in {"reviewer", "both"}:
        raise ReviewError("provider-not-reviewer")
    capabilities = set(provider.get("capabilities", []))
    if not {"read", "structured_output"}.issubset(capabilities) or capabilities & {"write", "shell"}:
        raise ReviewError("reviewer-capability-violation")
    base_url, model, key_env = provider.get("base_url"), provider.get("model"), provider.get("key_env")
    if not all(isinstance(value, str) and value for value in (base_url, model, key_env)):
        raise ReviewError("invalid-reviewer-config")
    repo = Path(str(request.get("repo") or request.get("worktree") or ".")).resolve()
    if not repo.is_dir():
        raise ReviewError("invalid-worktree")
    raw_value = request.get("raw_output")
    if not isinstance(raw_value, str) or not raw_value:
        raise ReviewError("raw-output-required")
    raw_path = Path(raw_value).expanduser()
    raw_output = (raw_path if raw_path.is_absolute() else repo / raw_path).resolve()
    try:
        raw_rel = raw_output.relative_to(repo)
    except ValueError as exc:
        raise ReviewError("raw-output-must-be-control-artifact") from exc
    if not raw_rel.parts or raw_rel.parts[0] != ".parallax" or "reviews" not in raw_rel.parts or not raw_output.name.endswith(".raw.json"):
        raise ReviewError("raw-output-must-be-review-receipt")
    prompt = request.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ReviewError("review-prompt-required")
    secret = _secret(repo, key_env)
    if not secret:
        raise ReviewError("missing-key")
    context = _context(request, repo)
    schema_path = Path(str(request.get("schema") or ROUND_SCHEMA)).resolve()
    if schema_path != ROUND_SCHEMA.resolve():
        raise ReviewError("unsupported-review-schema")
    schema_text = json.dumps(_json(schema_path), indent=2, sort_keys=True)
    user_prompt = (prompt.rstrip() + "\n\n"
                   "Return exactly one JSON object validating against this FULL schema. "
                   "Do not include markdown fences or commentary.\n"
                   "===== FULL REVIEW SCHEMA =====\n" + schema_text +
                   ("\n===== ASSEMBLED READ-ONLY CONTEXT =====" + context if context else ""))
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a read-only independent Parallax reviewer. Return only the requested JSON object."},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0,
        "max_tokens": int(provider.get("review_max_tokens", 12000)),
        "response_format": {"type": "json_object"},
    }
    body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
    if secret in body_bytes.decode("utf-8"):
        raise ReviewError("secret-in-request")
    before = _snapshot(repo, raw_output)
    http_request = urllib.request.Request(base_url, data=body_bytes, method="POST")
    http_request.add_header("Authorization", f"Bearer {secret}")
    http_request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(http_request, timeout=float(request.get("timeout_s", provider.get("review_timeout_s", 180)))) as response:
            payload = json.loads(response.read(16 * 1024 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code in {401, 403}:
            raise ReviewError("auth-failed") from exc
        if exc.code == 402:
            raise ReviewError("insufficient_balance") from exc
        if exc.code in {408, 409, 429}:
            raise ReviewError("rate-limited") from exc
        raise ReviewError("provider-http-error") from exc
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        raise ReviewError("provider-timeout-or-network") from exc
    _assert_unchanged(repo, before, raw_output)
    try:
        verdict = json.loads(_response_content(payload))
    except json.JSONDecodeError as exc:
        raise ReviewError("malformed-provider-json") from exc
    if not isinstance(verdict, dict):
        raise ReviewError("review-not-object")
    _validate(verdict, schema_path)
    _atomic_write(raw_output, verdict)
    return {"status": "ok", "provider": provider_name, "transport": "review-api", "model": model,
            "raw_artifact": str(raw_output), "verdict": verdict}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--request", required=True)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--provider", required=True)
    args = ap.parse_args(argv)
    try:
        from provider_runtime import load_registry
        request = _json(Path(args.request).resolve())
        repo = Path(str(request.get("repo") or request.get("worktree") or ".")).resolve()
        registry, _ = load_registry(repo, Path(args.registry).resolve())
        print(json.dumps(run_review(request, registry, args.provider), indent=2, sort_keys=True, ensure_ascii=False))
        return 0
    except ReviewError as exc:
        print(json.dumps({"status": "error", "error_class": exc.error_class}, sort_keys=True))
        return 2
    except Exception:
        print(json.dumps({"status": "error", "error_class": "runtime-error"}, sort_keys=True))
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
