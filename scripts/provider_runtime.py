#!/usr/bin/env python3
"""Provider-agnostic Parallax runtime primitives.

This module is deliberately small and mechanical.  It does not decide whether a
worker satisfied a spec: it validates the provider contract, enforces the
visibility manifest and existing blindfold guard, owns the commit, and records
normalized attempt facts.  Provider output is never copied into a Parallax
contract or receipt; bounded redacted transport logs are the only optional
artifacts.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import random
import sqlite3
import tomllib
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
BLINDFOLD = ROOT / "scripts" / "blindfold-guard.py"
REGISTRY_SCHEMA = ROOT / "assets" / "provider-registry.schema.json"
PLAN_SCHEMA = ROOT / "assets" / "provider-plan.schema.json"
ATTEMPT_SCHEMA = ROOT / "assets" / "worker-attempt.schema.json"
BUDGET_SCHEMA = ROOT / "assets" / "provider-budget.schema.json"
LIMITS_SCHEMA = ROOT / "assets" / "provider-limits.schema.json"
OPENROUTER_SCHEMA = ROOT / "assets" / "openrouter-provider.schema.json"
DEFAULT_CHAINS = {
    "blind_coder": ["codex", "zai", "deepseek", "claude"],
    "test_writer": ["codex", "zai", "deepseek", "claude"],
    "arbiter": ["codex", "zai"],
    "cross_model_verifier": ["codex", "zai", "gemini"],
}
ROLE_ALIASES = {"blind-coder": "blind_coder", "test-writer": "test_writer"}
EDITING_ROLES = {"blind-coder", "test-writer", "arbiter"}
SECRET_KEYS = re.compile(r"(?:key|token|secret|password|credential|api[_-]?key)$", re.I)
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LIMIT_RE = re.compile(r"rate.?limit|quota|usage.?limit|too many requests|429|exhausted", re.I)
AUTH_RE = re.compile(r"unauthori[sz]ed|authentication|invalid api key|permission denied|401|403", re.I)
BALANCE_RE = re.compile(r"insufficient balance|balance exhausted|insufficient funds|business.?code\s*[:=]?\s*(?:1113|402)|(?:http|status|code|error_code)\s*[:=]?\s*402|\b1113\b", re.I)
SOURCE_CLASSES = {"official-api", "official-cli", "official-dashboard", "local-health-probe", "unknown"}
HOSTS = {"claude-code", "codex", "shell"}
PROVIDER_ALIASES = {"z.ai": "zai", "zai-api": "zai", "claude-code": "claude"}
LIMIT_ACTIONS = {"continue", "handoff", "sleep_until_reset", "unknown"}


def _routing_config(provider: dict[str, Any]) -> dict[str, Any]:
    value = provider.get("routing") or provider.get("provider") or {}
    return value if isinstance(value, dict) else {}


STATE_STATUSES = {"unknown", "healthy", "warning", "exhausted", "rate_limited", "auth_failed", "stale"}


class ProviderStateStore:
    """Small local routing memory; it is never copied into git artifacts."""

    def __init__(self, path: Path):
        self.path = path.expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self.path.touch(mode=0o600)
        else:
            self.path.chmod(0o600)
        self.db = sqlite3.connect(str(self.path))
        self.db.row_factory = sqlite3.Row
        self.db.execute("""CREATE TABLE IF NOT EXISTS provider_state (
            state_key TEXT PRIMARY KEY, provider TEXT NOT NULL, transport TEXT NOT NULL,
            key_fingerprint TEXT NOT NULL, model TEXT, upstream_model TEXT, project_scope TEXT,
            last_status TEXT NOT NULL, last_error_class TEXT, provider_code TEXT,
            observed_at TEXT NOT NULL, reset_at TEXT, next_probe_at TEXT,
            source_class TEXT NOT NULL, confidence TEXT NOT NULL, balance_scope TEXT NOT NULL,
            remaining REAL, operator_budget_remaining REAL, consecutive_failures INTEGER NOT NULL,
            last_probe_ok INTEGER NOT NULL DEFAULT 0
        )""")
        self.db.commit()

    @staticmethod
    def key(provider: str, transport: str, fingerprint: str, model: str | None,
            upstream_model: str | None, project_scope: str | None) -> str:
        payload = json.dumps({"provider": provider, "transport": transport, "key_fingerprint": fingerprint,
                              "model": model, "upstream_model": upstream_model, "project_scope": project_scope},
                             sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode()).hexdigest()

    def get(self, provider: str, transport: str, fingerprint: str, model: str | None = None,
            upstream_model: str | None = None, project_scope: str | None = None) -> dict[str, Any] | None:
        key = self.key(provider, transport, fingerprint, model, upstream_model, project_scope)
        row = self.db.execute("SELECT * FROM provider_state WHERE state_key=?", (key,)).fetchone()
        return dict(row) if row else None

    def put(self, *, provider: str, transport: str, fingerprint: str, model: str | None,
            upstream_model: str | None, project_scope: str | None, status: str,
            error_class: str | None = None, provider_code: str | None = None,
            observed_at: str | None = None, reset_at: str | None = None,
            next_probe_at: str | None = None, source_class: str = "unknown",
            confidence: str = "low", balance_scope: str = "unknown", remaining: float | None = None,
            operator_budget_remaining: float | None = None, last_probe_ok: bool = False) -> dict[str, Any]:
        if status not in STATE_STATUSES:
            raise ValueError(f"invalid provider state {status!r}")
        observed_at = observed_at or now()
        key = self.key(provider, transport, fingerprint, model, upstream_model, project_scope)
        prior = self.get(provider, transport, fingerprint, model, upstream_model, project_scope)
        failures = 0 if last_probe_ok or status == "healthy" else (int(prior["consecutive_failures"]) if prior else 0) + 1
        if operator_budget_remaining is None and prior:
            operator_budget_remaining = prior.get("operator_budget_remaining")
        self.db.execute("""INSERT INTO provider_state
          (state_key,provider,transport,key_fingerprint,model,upstream_model,project_scope,last_status,last_error_class,provider_code,observed_at,reset_at,next_probe_at,source_class,confidence,balance_scope,remaining,operator_budget_remaining,consecutive_failures,last_probe_ok)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(state_key) DO UPDATE SET last_status=excluded.last_status,last_error_class=excluded.last_error_class,provider_code=excluded.provider_code,observed_at=excluded.observed_at,reset_at=excluded.reset_at,next_probe_at=excluded.next_probe_at,source_class=excluded.source_class,confidence=excluded.confidence,balance_scope=excluded.balance_scope,remaining=excluded.remaining,operator_budget_remaining=excluded.operator_budget_remaining,consecutive_failures=excluded.consecutive_failures,last_probe_ok=excluded.last_probe_ok""",
                     (key, provider, transport, fingerprint, model, upstream_model, project_scope, status,
                      error_class, provider_code, observed_at, reset_at, next_probe_at, source_class, confidence,
                      balance_scope, remaining, operator_budget_remaining, failures, int(last_probe_ok)))
        self.db.commit()
        return self.get(provider, transport, fingerprint, model, upstream_model, project_scope) or {}

    def clear(self, provider: str | None = None, fingerprint: str | None = None) -> None:
        if provider and fingerprint:
            self.db.execute("DELETE FROM provider_state WHERE provider=? AND key_fingerprint=?", (provider, fingerprint))
        elif provider:
            self.db.execute("DELETE FROM provider_state WHERE provider=?", (provider,))
        else:
            self.db.execute("DELETE FROM provider_state")
        self.db.commit()

    def close(self) -> None:
        self.db.close()


def _state_path(registry: dict[str, Any]) -> Path:
    value = registry.get("provider_state_db") or os.environ.get("PARALLAX_PROVIDER_STATE_DB")
    return Path(str(value)).expanduser() if value else Path.home() / ".config" / "parallax" / "provider-state.sqlite"


def _credential_fingerprint(repo: Path, provider: dict[str, Any]) -> str:
    key_env = provider.get("key_env")
    if not key_env:
        return "no-credential"
    env = _child_env(repo, key_env)
    value = env.get(key_env)
    if not value:
        return "missing"
    return hashlib.sha256(value.encode()).hexdigest()[:32]


def _state_identity(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any]) -> dict[str, Any]:
    routing = _routing_config(provider)
    upstream_model = provider.get("model") if provider.get("transport") == "openrouter-api" else None
    return {"provider": name, "transport": str(provider.get("transport", "unknown")),
            "fingerprint": _credential_fingerprint(repo, provider), "model": provider.get("model"),
            "upstream_model": upstream_model, "project_scope": provider.get("project_scope"),
            "upstream_provider": (routing.get("only") or [None])[0]}


def _load_provider_state(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any]) -> tuple[ProviderStateStore, dict[str, Any] | None, dict[str, Any]]:
    identity = _state_identity(repo, name, provider, registry)
    store = ProviderStateStore(_state_path(registry))
    state = store.get(identity["provider"], identity["transport"], identity["fingerprint"], identity["model"],
                       identity["upstream_model"], identity["project_scope"])
    return store, state, identity


def _state_is_blocking(state: dict[str, Any] | None, *, recheck: bool = False) -> bool:
    if not state or recheck or state.get("last_status") not in {"exhausted", "auth_failed", "rate_limited"}:
        return False
    next_probe = state.get("next_probe_at")
    if not next_probe:
        return True
    # _snapshot_age_seconds is now-next; a future next_probe has a negative
    # raw delta, so parse it explicitly here.
    try:
        due = datetime.fromisoformat(str(next_probe).replace("Z", "+00:00")).timestamp() <= time.time()
    except (TypeError, ValueError, OverflowError):
        due = False
    return not due


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def fail(message: str, code: int = 2) -> int:
    print(json.dumps({"error": message}, sort_keys=True))
    return code


def _json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _schema_validate(doc: Any, path: Path) -> None:
    try:
        import jsonschema
    except ImportError as exc:
        raise RuntimeError(f"jsonschema is required for a provider artifact write: {exc}")
    jsonschema.validate(doc, _json(path))


def _secret_values(doc: Any, path: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(doc, dict):
        for key, value in doc.items():
            here = f"{path}.{key}" if path else str(key)
            key_name = str(key)
            if SECRET_KEYS.search(key_name) and not (key_name.lower().endswith("_env") and ENV_NAME.fullmatch(str(value or ""))):
                if value not in (None, "", []):
                    found.append(here)
            found.extend(_secret_values(value, here))
    elif isinstance(doc, list):
        for idx, value in enumerate(doc):
            found.extend(_secret_values(value, f"{path}[{idx}]"))
    return found


def _repo_tracked(repo: Path, path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(repo.resolve())
    except ValueError:
        return False
    p = subprocess.run(["git", "-C", str(repo), "ls-files", "--error-unmatch", "--", str(rel)],
                       capture_output=True, text=True)
    return p.returncode == 0


def _tracked_secret_carriers(repo: Path) -> list[str]:
    p = subprocess.run(["git", "-C", str(repo), "ls-files"], capture_output=True, text=True)
    if p.returncode != 0:
        return []
    out = []
    for rel in p.stdout.splitlines():
        name = Path(rel).name
        if name == ".env" or name.endswith(".env") or name in {"providers.env", "zai.env"}:
            out.append(rel)
    return out


def _dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key] = value
    return values


def _validate_registry_doc(doc: Any) -> dict[str, Any]:
    if not isinstance(doc, dict):
        raise ValueError("provider registry must be an object")
    secret_paths = _secret_values(doc)
    if secret_paths:
        raise ValueError("provider registry contains secret values at: " + ", ".join(secret_paths))
    if not isinstance(doc.get("providers"), dict) or not doc["providers"]:
        raise ValueError("provider registry must contain [providers.<name>] entries")
    for name, provider in doc["providers"].items():
        if not isinstance(provider, dict):
            raise ValueError(f"provider {name!r} must be a table")
        for key in ("transport", "kind"):
            if not isinstance(provider.get(key), str) or not provider[key]:
                raise ValueError(f"provider {name!r} requires {key}")
        if provider["transport"] in {"codex-cli", "aider-api", "openrouter-api", "native-claude"} and not provider.get("command"):
            raise ValueError(f"provider {name!r} requires command for {provider['transport']}")
        if provider["transport"] == "openrouter-api":
            if provider.get("key_env") != "OPENROUTER_API_KEY":
                raise ValueError(f"provider {name!r} openrouter-api requires key_env=OPENROUTER_API_KEY")
            if provider.get("key_env") == "ZAI_API_KEY" or provider.get("credential_class") in {"zai-api", "zai-coding-subscription"}:
                raise ValueError(f"provider {name!r} must not mix OpenRouter and z.ai credentials")
            if "management_key_env" in provider:
                raise ValueError("use credits_key_env for OpenRouter management credentials")
            if provider.get("credits_key_env") == provider.get("key_env"):
                raise ValueError(f"provider {name!r} credits_key_env must differ from key_env")
            routing = _routing_config(provider)
            if not isinstance(routing, dict):
                raise ValueError(f"provider {name!r} routing must be a table")
            _schema_validate(provider, OPENROUTER_SCHEMA)
        if provider["transport"] == "aider-api" and provider.get("credential_class") == "claude-consumer-oauth":
            raise ValueError(f"provider {name!r} cannot forward Claude consumer OAuth through Aider/API")
        if provider.get("auth_probe"):
            if provider.get("auth_probe") != "zai-models" or provider.get("key_env") != "ZAI_API_KEY":
                raise ValueError(f"provider {name!r} has unsupported auth_probe")
            if provider.get("auth_endpoint") != "https://api.z.ai/api/paas/v4/models":
                raise ValueError(f"provider {name!r} z.ai auth_probe requires the official models endpoint")
            if str(provider.get("auth_method", "GET")).upper() != "GET":
                raise ValueError(f"provider {name!r} auth_probe must use GET")
        if provider["transport"] == "aider-api" and provider.get("key_env"):
            if not ENV_NAME.fullmatch(provider["key_env"]):
                raise ValueError(f"provider {name!r} key_env is not an environment variable name")
        if provider.get("credits_key_env") and not ENV_NAME.fullmatch(provider["credits_key_env"]):
            raise ValueError(f"provider {name!r} credits_key_env is not an environment variable name")
        source_class = provider.get("budget_source_class", "unknown")
        if source_class not in SOURCE_CLASSES:
            raise ValueError(f"provider {name!r} has invalid budget_source_class")
    _schema_validate(doc, REGISTRY_SCHEMA)
    return doc


def load_registry(repo: Path, config: Path | None = None) -> tuple[dict[str, Any], Path]:
    path = config or (repo / ".parallax" / "providers.toml")
    if not path.exists():
        raise ValueError(f"provider registry not found: {path}")
    try:
        doc = tomllib.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"provider registry is not valid TOML: {exc}")
    validated = _validate_registry_doc(doc)
    tracked = _tracked_secret_carriers(repo)
    if tracked:
        raise ValueError("tracked provider secret carrier(s): " + ", ".join(tracked))
    return validated, path


def _env_candidates(repo: Path) -> list[tuple[Path, str]]:
    return [
        (repo / ".parallax" / ".env", "project-local"),
        (repo / ".parallax" / "zai.env", "project-local"),
        (Path.home() / ".config" / "parallax" / "providers.env", "user-local"),
    ]


def discover_secret(repo: Path, key_env: str | None) -> dict[str, Any]:
    if not key_env:
        return {"configured": True, "source": None}
    values: dict[str, tuple[str, str]] = {}
    for path, source in _env_candidates(repo):
        for key, value in _dotenv(path).items():
            if key not in values and value:
                values[key] = (source, str(path))
    if key_env in os.environ and os.environ[key_env]:
        # The process environment is intentionally not called a persistence source.
        return {"configured": True, "source": "process", "key_env": key_env}
    if key_env in values:
        return {"configured": True, "source": values[key_env][0], "key_env": key_env}
    return {"configured": False, "source": None, "key_env": key_env}


def _child_env(repo: Path, key_env: str | None, blocked_env: set[str] | None = None) -> dict[str, str]:
    env = os.environ.copy()
    if key_env and not env.get(key_env):
        for candidate, _ in _env_candidates(repo):
            values = _dotenv(candidate)
            if values.get(key_env):
                env[key_env] = values[key_env]
                break
    for name in (blocked_env or set()) | {"OPENROUTER_MANAGEMENT_KEY"}:
        if name != key_env:
            env.pop(name, None)
    return env


def _aider_child_env(provider: dict[str, Any], env: dict[str, str]) -> dict[str, str]:
    """Adapt Parallax provider credentials to Aider's OpenAI-compatible contract."""
    child = dict(env)
    key_env = provider.get("key_env")
    if provider.get("transport") == "aider-api" and key_env and child.get(key_env):
        # Aider/LiteLLM reads OpenAI-compatible credentials from this name,
        # while Parallax keeps provider-specific names in its registry.
        child["OPENAI_API_KEY"] = child[key_env]
    return child


def _command_available(command: str | None) -> tuple[bool, str | None]:
    if not command:
        return True, None
    argv = shlex.split(command)
    if not argv:
        return False, None
    found = shutil.which(argv[0])
    return bool(found), found


def _aider_version(request: dict[str, Any], provider: dict[str, Any], argv: list[str]) -> tuple[int, ...]:
    available, _ = _command_available(str(provider.get("command", "")))
    if not available:
        raise ValueError("aider_missing")
    try:
        proc = subprocess.run(argv + ["--version"], cwd=request.get("worktree", "."),
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=float(provider.get("version_timeout_s", 10)),
                              env={k: v for k, v in {**os.environ, "AIDER_CHECK_UPDATE": "false"}.items()
                                   if k != "OPENROUTER_MANAGEMENT_KEY"})
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError("aider_missing")
    match = re.search(r"(?<!\d)(\d+)\.(\d+)(?:\.(\d+))?", (proc.stdout or "") + "\n" + (proc.stderr or ""))
    if proc.returncode != 0 or not match:
        raise ValueError("unsupported_openrouter_invocation")
    return tuple(int(part or 0) for part in match.groups())


def _probe_allowed(registry: dict[str, Any], provider: dict[str, Any], *, probe_auth: bool = False,
                   probe_all: bool = False) -> bool:
    """Arbitrary probes require both policy and an explicit CLI opt-in."""
    if not (probe_auth or probe_all):
        return False
    if registry.get("probe_policy", "explicit") != "explicit":
        return False
    if not provider.get("probe_read_only", False):
        return False
    return bool(provider.get("probe_command"))


def _arbitrary_command_allowed(registry: dict[str, Any], provider: dict[str, Any], command_key: str,
                               *, probe_auth: bool = False, probe_all: bool = False) -> bool:
    """Only explicit, declared read-only commands may receive provider env."""
    return bool((probe_auth or probe_all) and registry.get("probe_policy", "explicit") == "explicit"
                and provider.get("probe_read_only") is True and provider.get(command_key))


def _http_auth_probe(repo: Path, provider: dict[str, Any]) -> tuple[str, str | None, int | None]:
    """Run only the allowlisted z.ai GET models auth/availability adapter."""
    if (provider.get("auth_probe") != "zai-models"
            or provider.get("key_env") != "ZAI_API_KEY"
            or provider.get("auth_endpoint") != "https://api.z.ai/api/paas/v4/models"
            or str(provider.get("auth_method", "GET")).upper() != "GET"):
        return "unsupported", "invalid_auth_probe", None
    key_env = provider["key_env"]
    secret = discover_secret(repo, key_env)
    if not secret.get("configured"):
        return "not_configured", "missing-key", None
    env = _child_env(repo, key_env, blocked_env={str(provider.get("credits_key_env"))} if provider.get("credits_key_env") else None)
    value = env.get(key_env)
    if not value:
        return "not_configured", "missing-key", None
    request = urllib.request.Request(str(provider["auth_endpoint"]), method="GET")
    request.add_header("Authorization", f"Bearer {value}")
    try:
        with urllib.request.urlopen(request, timeout=float(provider.get("auth_timeout_s", 15))) as response:
            status = int(response.getcode() or getattr(response, "status", 0))
        if status == 200:
            return "http_200", None, status
        if status == 401:
            return "http_401", "auth_failed", status
        return "http_error", "http_error", status
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return "http_401", "auth_failed", exc.code
        return "http_error", "http_error", exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return "network_failure", "network_failure", None


def _provider_report(repo: Path, name: str, p: dict[str, Any], registry: dict[str, Any] | None = None,
                     *, probe_auth: bool = False, probe_all: bool = False) -> dict[str, Any]:
    available, path = _command_available(str(p.get("command", "")))
    secret = discover_secret(repo, p.get("key_env"))
    # Configuration (credential/registry presence) is distinct from executable
    # availability.  A read-only OpenRouter key probe must work even when the
    # optional Aider worker binary is not installed.
    configured = bool(secret.get("configured", True))
    probe = "not-supported"
    probe_error = None
    probe_http_status = None
    if p.get("auth_probe"):
        if probe_auth or probe_all:
            probe, probe_error, probe_http_status = _http_auth_probe(repo, p)
        else:
            probe = "not-run-explicit-opt-in-required"
            probe_error = "explicit_probe_required"
    elif p.get("probe_command") and _probe_allowed(registry or {}, p, probe_auth=probe_auth, probe_all=probe_all):
        try:
            probe_proc = subprocess.run(shlex.split(str(p["probe_command"])), cwd=repo,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, env=_child_env(repo, p.get("key_env")),
                                        timeout=float(p.get("probe_timeout_s", 15)))
            probe = "ok" if probe_proc.returncode == 0 else "failed"
        except subprocess.TimeoutExpired:
            probe = "timeout"
        except (OSError, ValueError):
            probe = "failed"
    elif p.get("probe_command"):
        probe = "not-run-explicit-opt-in-required"
    elif p.get("transport") == "native-claude":
        probe = "host-native"
    report = {
        "provider": name,
        "kind": p.get("kind"),
        "transport": p.get("transport"),
        "model": p.get("model"),
        "command_available": available,
        "command_path": path,
        "configured": configured,
        "secret_source": secret.get("source"),
        "probe_status": probe,
        "probe_error_class": probe_error,
        "probe_http_status": probe_http_status,
        "live_signal_status": "configured" if (p.get("live_signal_command") or p.get("live_signal_path")) else "not-supported",
        "authenticated": "yes" if probe in {"ok", "http_200"} else ("no" if probe == "http_401" else ("unknown" if available and configured else ("no" if not secret.get("configured", True) else "unknown"))),
    }
    if p.get("transport") == "aider-api" and not available:
        report["availability"] = "provider-unavailable"
    elif not configured:
        report["availability"] = "not-configured"
    else:
        report["availability"] = "available-or-unknown-auth"
    return report


def _path_value(payload: Any, dotted: str | None) -> Any:
    value = payload
    if not dotted:
        return value
    for part in dotted.split("."):
        if isinstance(value, list) and part.isdigit() and int(part) < len(value):
            value = value[int(part)]
        elif isinstance(value, dict) and part in value:
            value = value[part]
        else:
            return None
    return value


def _normalize_reset_value(value: Any) -> str | None:
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value), tz=timezone.utc).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and value:
        if value.isdigit():
            return _normalize_reset_value(float(value))
        return value
    return None


def _budget_endpoint(repo: Path, p: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    use_credits = p.get("transport") == "openrouter-api" and p.get("credits_endpoint") and p.get("credits_key_env") and \
        discover_secret(repo, p.get("credits_key_env")).get("configured")
    endpoint = (p.get("credits_endpoint") if use_credits else None) or p.get("budget_key_endpoint") or p.get("budget_endpoint")
    if not endpoint:
        return None, None
    request = urllib.request.Request(str(endpoint), method=str(p.get("budget_method", "GET")).upper())
    key_env = p.get("credits_key_env") if use_credits else p.get("key_env")
    secret = discover_secret(repo, key_env)
    env = _child_env(repo, key_env)
    if key_env and not secret.get("configured"):
        return None, "missing-key"
    if key_env and env.get(key_env):
        request.add_header("Authorization", f"Bearer {env[key_env]}")
    try:
        with urllib.request.urlopen(request, timeout=float(p.get("budget_timeout_s", 10))) as response:
            payload = json.loads(response.read().decode("utf-8"))
        if not isinstance(payload, dict):
            return None, "malformed-budget-probe"
        remaining_path = p.get("budget_remaining_path")
        reset_path = p.get("budget_reset_path")
        if use_credits:
            total_credits = _path_value(payload, p.get("credits_total_path") or "total_credits")
            total_usage = _path_value(payload, p.get("credits_usage_path") or "total_usage")
            remaining = total_credits - total_usage if isinstance(total_credits, (int, float)) and isinstance(total_usage, (int, float)) else None
            result = {"status": "known" if remaining is not None else "unknown", "remaining": remaining,
                      "limit": total_credits, "currency": p.get("budget_currency"), "reset_at": None,
                      "exact_balance": bool(p.get("budget_exact", False)), "balance_scope": "openrouter-account"}
            return result, None
        if p.get("transport") == "openrouter-api" and p.get("budget_key_endpoint"):
            remaining_path = remaining_path or "limit_remaining"
            reset_path = reset_path or "limit_reset"
        remaining = _path_value(payload, remaining_path)
        limit = _path_value(payload, p.get("budget_limit_path") or ("limit" if p.get("transport") == "openrouter-api" else None))
        result = {
            "status": "known" if isinstance(remaining, (int, float)) else "unknown",
            "remaining": remaining,
            "limit": limit,
            "currency": _path_value(payload, p.get("budget_currency_path")) if p.get("budget_currency_path") else None,
            "reset_at": _normalize_reset_value(_path_value(payload, reset_path)),
            "exact_balance": bool(p.get("budget_exact", False)),
            "limit_signal": _path_value(payload, p.get("budget_limit_signal_path")) if p.get("budget_limit_signal_path") else None,
            "plan": _path_value(payload, p.get("budget_plan_path")) if p.get("budget_plan_path") else None,
            "balance_scope": p.get("balance_scope", "unknown"),
        }
        if p.get("transport") == "openrouter-api" and isinstance(remaining, (int, float)) and isinstance(limit, (int, float)) and limit > 0:
            result["used_percentage"] = max(0.0, min(100.0, (1.0 - remaining / limit) * 100.0))
        return result, None
    except (OSError, ValueError, urllib.error.URLError, TimeoutError):
        return None, "budget-probe-failed"


def _normalize_model_entry(entry: Any) -> dict[str, Any] | None:
    if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
        return None
    pricing = entry.get("pricing") if isinstance(entry.get("pricing"), dict) else {}
    architecture = entry.get("architecture") if isinstance(entry.get("architecture"), dict) else {}
    capabilities = entry.get("supported_parameters")
    if not isinstance(capabilities, list):
        capabilities = architecture.get("input_modalities", []) + architecture.get("output_modalities", [])
    return {"id": entry["id"],
            "pricing": {str(k): str(v) for k, v in pricing.items() if isinstance(v, (str, int, float))},
            "capabilities": sorted({str(v) for v in capabilities if isinstance(v, str)})}


def _openrouter_catalog(repo: Path, provider: dict[str, Any]) -> dict[str, Any]:
    """Read and normalize /models metadata; never retain raw provider JSON."""
    requested = provider.get("model")
    empty = {"status": "not-probed", "requested_model": requested, "models": []}
    endpoint = provider.get("models_endpoint")
    if not endpoint:
        return empty
    secret = discover_secret(repo, provider.get("key_env"))
    if not secret.get("configured"):
        return {**empty, "status": "unavailable"}
    request = urllib.request.Request(str(endpoint), method="GET")
    env = _child_env(repo, provider.get("key_env"))
    if env.get(provider.get("key_env", "")):
        request.add_header("Authorization", f"Bearer {env[provider['key_env']]}")
    try:
        with urllib.request.urlopen(request, timeout=float(provider.get("budget_timeout_s", 10))) as response:
            payload = json.loads(response.read().decode("utf-8"))
        models = payload.get("data") if isinstance(payload, dict) else None
        normalized = [item for item in (_normalize_model_entry(value) for value in (models or [])) if item]
        available = any(item["id"] == requested for item in normalized)
        return {"status": "available" if available else "model_unavailable",
                "requested_model": requested, "models": normalized}
    except (OSError, ValueError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return {**empty, "status": "unavailable"}


def _budget_report(repo: Path, name: str, p: dict[str, Any], provider_report: dict[str, Any], probe_budget: bool = False,
                   *, registry: dict[str, Any] | None = None, probe_auth: bool = False,
                   probe_all: bool = False) -> dict[str, Any]:
    source_class = str(p.get("budget_source_class", "unknown"))
    budget: dict[str, Any] = {
        "status": "unknown",
        "currency": None,
        "remaining": None,
        "reset_at": None,
        "source": "not-supported",
        "source_class": source_class,
        "observed_at": now(),
    }
    error_class = None
    # The v0.40 configured budget adapter is already a declared read-only
    # adapter. `probe_budget` gates network endpoints; arbitrary probe_command
    # remains separately opt-in.
    command = p.get("budget_command")
    payload = None
    if probe_budget and not command and (p.get("budget_endpoint") or p.get("budget_key_endpoint") or p.get("credits_endpoint")):
        payload, error_class = _budget_endpoint(repo, p)
        if payload is not None:
            command = None
    if not provider_report["command_available"] and payload is None:
        budget["status"] = "unavailable"
        budget["source"] = None
    elif command and payload is None and _arbitrary_command_allowed(registry or {}, p, "budget_command",
                                                                    probe_auth=probe_auth, probe_all=probe_all):
        try:
            args = shlex.split(str(command))
            proc = subprocess.run(args, cwd=repo, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, timeout=float(p.get("budget_timeout_s", 10)),
                                  env={**_child_env(repo, p.get("key_env")), "PARALLAX_BUDGET_PROBE": "1"})
            payload = json.loads(proc.stdout) if proc.returncode == 0 else None
            if not isinstance(payload, dict) or payload.get("status") not in {"known", "limited", "unknown", "unavailable"}:
                error_class = "malformed-budget-probe"
            else:
                for key in ("status", "currency", "remaining", "reset_at", "used_percentage", "balance_scope"):
                    if key in payload:
                        budget[key] = payload[key]
                budget["source"] = "provider-adapter" if source_class == "official-api" else ("local-cli" if source_class == "official-cli" else "not-supported")
                if payload.get("limit") is not None:
                    budget["limit"] = payload["limit"]
                if payload.get("limit_signal") is not None:
                    budget["limit_signal"] = payload["limit_signal"]
                if payload.get("plan") is not None:
                    budget["plan"] = payload["plan"]
                exact_source = source_class in {"official-api", "official-cli"} and payload.get("exact_balance") is True
                if budget["status"] in {"known", "limited"} and not exact_source:
                    error_class = "non-exact-source"
                    budget = {**budget, "status": "unknown", "remaining": None, "currency": None, "reset_at": None, "source": "not-supported"}
                if budget["status"] in {"known", "limited"} and not isinstance(budget["remaining"], (int, float)):
                    error_class = "budget-value-missing"
                    budget = {**budget, "status": "unknown", "remaining": None, "currency": None, "reset_at": None}
        except (OSError, ValueError, subprocess.TimeoutExpired):
            error_class = "budget-probe-failed"
    elif command and payload is None:
        error_class = "not-run-explicit-opt-in-required"
    if payload is not None and error_class is None:
        for key in ("status", "remaining", "currency", "reset_at", "limit_signal", "plan", "used_percentage", "balance_scope", "limit"):
            if key in payload:
                budget[key] = payload[key]
        exact_source = source_class in {"official-api", "official-cli"} and payload.get("exact_balance") is True
        if exact_source and isinstance(payload.get("remaining"), (int, float)):
            budget["status"] = payload.get("status", "known")
            budget["source"] = "provider-adapter" if source_class == "official-api" else "local-cli"
        elif payload.get("limit_signal") is not None:
            budget["limit_signal"] = payload["limit_signal"]
        if not exact_source:
            budget["status"] = "unknown"
            budget["remaining"] = None
            budget["currency"] = None
            budget["source"] = "not-supported"
            if error_class is None and payload.get("remaining") is not None:
                error_class = "non-exact-source"
    estimate = None
    if isinstance(p.get("estimated_input_tokens"), (int, float)) or isinstance(p.get("estimated_output_tokens"), (int, float)):
        estimate = {
            "label": "estimate",
            "input_tokens": p.get("estimated_input_tokens"),
            "output_tokens": p.get("estimated_output_tokens"),
            "cost_usd": None,
        }
        if isinstance(p.get("cost_per_1k_input_usd"), (int, float)) and isinstance(p.get("estimated_input_tokens"), (int, float)):
            estimate["cost_usd"] = round(p["estimated_input_tokens"] / 1000 * p["cost_per_1k_input_usd"], 8)
    confidence = "high" if budget["status"] in {"known", "limited"} and source_class in {"official-api", "official-cli"} else ("medium" if provider_report["configured"] else "low")
    result = {"provider": name, "configured": provider_report["configured"],
              "authenticated": provider_report["authenticated"], "budget": budget,
              "confidence": confidence}
    if estimate is not None:
        result["estimate"] = estimate
    if error_class:
        result["error_class"] = error_class
    return result


def preflight(repo: Path, config: Path | None, probe_budget: bool = False, *, probe_auth: bool = False,
              probe_all: bool = False) -> dict[str, Any]:
    registry, path = load_registry(repo, config)
    tracked = _tracked_secret_carriers(repo)
    if tracked:
        raise ValueError("tracked provider secret carrier(s): " + ", ".join(tracked))
    providers = []
    budgets = []
    for name, provider in registry["providers"].items():
        report = _provider_report(repo, name, provider, registry, probe_auth=probe_auth, probe_all=probe_all)
        providers.append(report)
        budgets.append(_budget_report(repo, name, provider, report, probe_budget=probe_budget,
                                      registry=registry, probe_auth=probe_auth, probe_all=probe_all))
    result = {"registry": str(path), "tracked_secret_carriers": [], "providers": providers,
              "budgets": budgets, "observed_at": now()}
    _schema_validate(result, BUDGET_SCHEMA)
    return result


def _provider_descriptor(name: str, p: dict[str, Any], preflight_item: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"provider": name, "kind": p.get("kind"), "transport": p.get("transport"),
            "model": p.get("model"), "base_url": p.get("base_url"),
            "capabilities": list(p.get("capabilities", [])),
            "configured": None if preflight_item is None else preflight_item.get("configured")}


def build_plan(repo: Path, config: Path | None, probe_budget: bool = False, *, probe_auth: bool = False,
               probe_all: bool = False) -> dict[str, Any]:
    registry, path = load_registry(repo, config)
    pf = preflight(repo, path, probe_budget=probe_budget, probe_auth=probe_auth, probe_all=probe_all)
    reports = {x["provider"]: x for x in pf["providers"]}
    roles = registry.get("roles", {})
    plan_roles = {}
    for role, default_chain in DEFAULT_CHAINS.items():
        cfg = roles.get(role, {}) if isinstance(roles, dict) else {}
        chain = cfg.get("chain", default_chain)
        plan_roles[role] = {
            "chain": list(chain),
            "required_capabilities": list(cfg.get("required_capabilities", ["read", "structured_output"] if role in {"arbiter", "cross_model_verifier"} else ["read", "write"])),
            "automatic_fallback": bool(cfg.get("automatic_fallback", True)),
        }
    proposed = {"schema_version": "parallax-provider-plan-v1", "created_at": now(),
                "host_provider": registry.get("host_provider", "claude-code"),
                "registry": str(path), "roles": plan_roles,
                "providers": [_provider_descriptor(n, p, reports.get(n)) for n, p in registry["providers"].items()],
                "budgets": pf["budgets"], "fallback_policy": registry.get("fallback_policy", "ordered-clean-base"),
                "confirmation_required": True}
    _schema_validate(proposed, PLAN_SCHEMA)
    return proposed


def freeze_plan(plan_path: Path, selection_path: Path, output: Path) -> dict[str, Any]:
    plan = _json(plan_path)
    selection = _json(selection_path)
    if selection.get("confirmed") is not True:
        raise ValueError("provider matrix requires explicit confirmed=true")
    providers = {p["provider"]: p for p in plan.get("providers", [])}
    selected_roles = selection.get("roles", plan.get("roles", {}))
    if not isinstance(selected_roles, dict) or not selected_roles:
        raise ValueError("provider matrix is empty")
    roles = {}
    for role, value in selected_roles.items():
        chain = value.get("chain") if isinstance(value, dict) else value
        if not isinstance(chain, list) or not chain:
            raise ValueError(f"role {role!r} requires a non-empty provider chain")
        for name in chain:
            if name not in providers:
                raise ValueError(f"role {role!r} selects unknown provider {name!r}")
        base = plan.get("roles", {}).get(role, {})
        roles[role] = {"chain": chain, "required_capabilities": value.get("required_capabilities", base.get("required_capabilities", [])),
                       "automatic_fallback": bool(value.get("automatic_fallback", base.get("automatic_fallback", True)))}
    chosen_names = {n for role in roles.values() for n in role["chain"]}
    frozen = {"schema_version": "parallax-provider-contract-v1", "frozen_at": now(),
              "host_provider": selection.get("host_provider", plan.get("host_provider", "claude-code")),
              "roles": roles,
              "providers": [p for p in plan.get("providers", []) if p["provider"] in chosen_names],
              "fallback_policy": selection.get("fallback_policy", plan.get("fallback_policy", "ordered-clean-base")),
              "budget_observations": [b for b in plan.get("budgets", []) if b.get("provider") in chosen_names],
              "limitations": ["budget observations are point-in-time and unknown is not zero or unlimited"],
              "automatic_fallback": {role: bool(value["automatic_fallback"]) for role, value in roles.items()}}
    if _secret_values(frozen):
        raise ValueError("refusing to freeze a provider contract containing secret values")
    _schema_validate(frozen, PLAN_SCHEMA)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(frozen, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return frozen


def _read_manifest(request: dict[str, Any]) -> dict[str, Any]:
    manifest = request.get("visibility_manifest", {})
    if isinstance(manifest, str):
        manifest = _json(Path(manifest))
    if not isinstance(manifest, dict):
        raise ValueError("visibility_manifest must be an object or JSON path")
    writable = manifest.get("writable_files", [])
    visible = manifest.get("visible_files", writable)
    if not isinstance(writable, list) or not isinstance(visible, list):
        raise ValueError("visibility manifest files must be arrays")
    if request.get("role") in EDITING_ROLES and not writable:
        raise ValueError("editing provider attempt has no explicit writable_files")
    for value in writable + visible:
        if not isinstance(value, str) or Path(value).is_absolute() or ".." in Path(value).parts:
            raise ValueError("visibility manifest contains an unsafe path")
    manifest["writable_files"] = writable
    manifest["visible_files"] = visible
    return manifest


def _git(repo: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    p = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "git command failed")
    return p


def _status_paths(worktree: Path) -> list[str]:
    p = _git(worktree, "status", "--porcelain=v1", "--untracked-files=all")
    if p.returncode != 0:
        raise RuntimeError("git status failed")
    paths = []
    for line in p.stdout.splitlines():
        if not line:
            continue
        value = line[3:] if len(line) >= 3 else ""
        if " -> " in value:
            value = value.split(" -> ", 1)[1]
        paths.append(value)
    return paths


def _redact(text: str, env: dict[str, str]) -> str:
    out = text
    for key, value in env.items():
        if key.endswith("_KEY") or "TOKEN" in key or "SECRET" in key:
            if value and len(value) >= 4:
                out = out.replace(value, "[REDACTED]")
    return out[:1_000_000]


def _blindfold(request: dict[str, Any], worktree: Path) -> tuple[bool, str]:
    side = request.get("side")
    slug = request.get("slug")
    if not side or not slug or not BLINDFOLD.exists():
        return True, "not-requested"
    cmd = [sys.executable, str(BLINDFOLD), "--worktree", str(worktree), "--side", side, "--slug", slug]
    scope = request.get("scope_manifest")
    if scope:
        cmd.extend(["--scope-manifest", str(scope)])
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return False, "blindfold-contaminated"
    return True, "clean"


def _classify(returncode: int | None, output: str, timed_out: bool = False) -> tuple[str, str]:
    if timed_out:
        return "timeout", "timeout"
    if BALANCE_RE.search(output):
        return "limit", "insufficient_balance"
    if LIMIT_RE.search(output):
        return "limit", "limit"
    if AUTH_RE.search(output):
        return "auth_error", "auth"
    if returncode == 0:
        return "provider_error", "empty_or_malformed_output"
    return "provider_error", "exit_nonzero"


def _find_signal(payload: Any) -> dict[str, Any]:
    """Normalize host/provider status input without treating health as quota."""
    if isinstance(payload, dict):
        used = payload.get("used_percentage", payload.get("quota_used_percentage"))
        reset = payload.get("resets_at", payload.get("reset_at"))
        signal = payload.get("limit_signal")
        if used is not None or reset is not None or signal is not None or payload.get("authenticated") is not None:
            return {"used_percentage": used, "resets_at": reset, "limit_signal": signal,
                    "authenticated": payload.get("authenticated", "unknown"),
                    "available": payload.get("available", True), "source_class": payload.get("source_class", "unknown"),
                    "observed_at": payload.get("observed_at", now()),
                    "window": payload.get("window"), "plan": payload.get("plan")}
        for value in payload.values():
            found = _find_signal(value)
            if found:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = _find_signal(value)
            if found:
                return found
    return {}


def _read_live_signal(provider: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    """Read a configured machine signal, never a model or arbitrary probe."""
    signal: dict[str, Any] = {}
    source = provider.get("live_signal_path") or request.get("live_signal_path")
    command = provider.get("live_signal_command")
    try:
        if source:
            signal = _find_signal(_json(Path(source)))
        elif command:
            proc = subprocess.run(shlex.split(str(command)), cwd=request.get("repo", request.get("worktree", ".")),
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, timeout=float(provider.get("live_signal_timeout_s", 10)),
                                  env=_child_env(Path(request.get("repo", request.get("worktree", "."))), provider.get("key_env")))
            if proc.returncode == 0:
                signal = _find_signal(json.loads(proc.stdout))
    except (OSError, ValueError, subprocess.TimeoutExpired, json.JSONDecodeError):
        signal = {}
    return signal


def _limits_policy(registry: dict[str, Any], provider: dict[str, Any]) -> dict[str, Any]:
    configured = registry.get("limits") if isinstance(registry.get("limits"), dict) else {}
    merged = {
        "warning_threshold_pct": 80.0,
        "handoff_threshold_pct": 90.0,
        "unknown_policy": "continue-with-warning",
        "stale_ttl_s": 120.0,
        "max_sleep_s": 3600.0,
        "reset_jitter_s": 30.0,
    }
    merged.update({k: v for k, v in configured.items() if k in merged})
    # v0.40 provider-local values remain accepted for compatibility, but the
    # registry policy is the canonical source for v0.40.1.
    for key in merged:
        if key not in configured and key in provider:
            merged[key] = provider[key]
    if merged["handoff_threshold_pct"] < merged["warning_threshold_pct"]:
        raise ValueError("limits handoff_threshold_pct must be >= warning_threshold_pct")
    return merged


def _limit_action(used: Any, signal_name: str | None, reset_seconds: float | None,
                  policy: dict[str, Any], fallback_available: bool,
                  last_status: str | None = None) -> tuple[str, str, bool]:
    explicit_auth = last_status == "auth_error"
    explicit_limit = last_status == "limit" or str(signal_name or "").lower() in {"limit", "limited", "exhausted", "near"}
    numeric = isinstance(used, (int, float))
    handoff_threshold = float(policy["handoff_threshold_pct"])
    warning_threshold = float(policy["warning_threshold_pct"])
    near = numeric and used >= warning_threshold
    exhausted = explicit_limit or (numeric and used >= handoff_threshold)
    if explicit_auth:
        return ("handoff" if fallback_available else "unknown", "limited", True)
    if exhausted:
        if fallback_available:
            return "handoff", "exhausted", True
        if reset_seconds is not None:
            return "sleep_until_reset", "exhausted", True
        return "unknown", "exhausted", True
    if near:
        return "continue", "near", True
    if not numeric and not explicit_limit:
        action = "continue" if policy["unknown_policy"] == "continue-with-warning" else "unknown"
        return action, "unknown", False
    return "continue", "healthy", True


def _snapshot_age_seconds(stamp: str | None) -> float | None:
    if not isinstance(stamp, str):
        return None
    try:
        return max(0.0, time.time() - datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp())
    except (TypeError, ValueError, OverflowError):
        return None


def _runtime_dir(request: dict[str, Any]) -> Path:
    if request.get("limits_runtime_dir"):
        return Path(str(request["limits_runtime_dir"])).resolve()
    root = Path(request.get("control_repo", request.get("repo", request.get("worktree", ".")))).resolve()
    return root / ".parallax" / str(request.get("slug", "provider-runtime")) / "runtime"


def _ensure_runtime_excluded(worktree: Path, runtime: Path) -> None:
    """Keep generated control files out of worker dirty-path accounting."""
    try:
        rel = runtime.resolve().relative_to(worktree.resolve())
        info = _git(worktree, "rev-parse", "--git-path", "info/exclude")
        if info.returncode != 0:
            return
        path = Path(info.stdout.strip())
        if not path.is_absolute():
            path = worktree / path
        line = f"/{rel.as_posix()}/limits.*"
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        if line not in existing.splitlines():
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(("\n" if existing and not existing.endswith("\n") else "") + line + "\n")
    except (OSError, ValueError):
        pass


def _safe_context_value(value: Any, fallback: str = "unknown") -> str:
    if value is None or isinstance(value, (dict, list)):
        return fallback
    text = str(value).replace("\n", " ").replace("\r", " ")
    return text[:120] or fallback


def _snapshot_context(snapshot: dict[str, Any]) -> str:
    used = snapshot["quota"]["used_percentage"]
    used_text = "unknown" if used is None else f"{used:g}%"
    reset = snapshot["quota"]["reset_at"] or snapshot["budget"]["reset_at"] or "unknown"
    age = _snapshot_age_seconds(snapshot.get("observed_at"))
    age_text = "unknown" if age is None else f"{int(age)}s"
    action = snapshot["action"]
    return ("[PARALLAX_LIMITS]\n"
            f"provider={_safe_context_value(snapshot['provider'])}; used={used_text}; "
            f"reset={_safe_context_value(reset)}; balance={'unknown' if snapshot['budget']['remaining'] is None else snapshot['budget']['remaining']}; "
            f"action={action}; source={snapshot['source_class']}; confidence={snapshot['confidence']}; age={age_text}; "
            f"upstream={_safe_context_value(snapshot.get('upstream_provider'))}; upstream_model={_safe_context_value(snapshot.get('upstream_model'))}; "
            f"balance_scope={snapshot.get('balance_scope', 'unknown')}; state={snapshot.get('routing_state', 'unknown')}; "
            f"estimate={snapshot['operator_estimate']['remaining'] if snapshot['operator_estimate']['remaining'] is not None else 'unknown'}; "
            f"allow_fallbacks={str(snapshot['routing']['allow_fallbacks']).lower()}\n"
            "RULE: do not query limits or spend a model request to check them.\n"
            "Supervisor action is authoritative: continue / handoff / sleep_until_reset.\n"
            "If action=handoff, do not start a new request. If action=sleep_until_reset, finish the current safe boundary and return a control receipt.\n")


def _snapshot_for_provider(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any],
                           request: dict[str, Any], *, fallback_available: bool = False,
                           last_status: str | None = None, probe_auth: bool = False,
                           probe_all: bool = False, probe_budget: bool = False,
                           previous: dict[str, Any] | None = None) -> dict[str, Any]:
    report = _provider_report(repo, name, provider, registry, probe_auth=probe_auth, probe_all=probe_all)
    state_store, state, identity = _load_provider_state(repo, name, provider, registry)
    signal = _read_live_signal(provider, request)
    policy = _limits_policy(registry, provider)
    used = signal.get("used_percentage")
    reset = signal.get("resets_at")
    source_class = str(signal.get("source_class") or provider.get("limits_source_class") or
                       provider.get("budget_source_class") or "unknown")
    if source_class not in SOURCE_CLASSES:
        source_class = "unknown"
    budget = _budget_report(repo, name, provider, report, probe_budget=probe_budget, registry=registry,
                            probe_auth=probe_auth, probe_all=probe_all)["budget"]
    budget_scope = budget.get("balance_scope")
    model_catalog = (_openrouter_catalog(repo, provider) if provider.get("transport") == "openrouter-api" and probe_budget
                     else {"status": "not-probed", "requested_model": provider.get("model"), "models": []})
    if used is None and isinstance(budget.get("used_percentage"), (int, float)):
        used = budget["used_percentage"]
    if reset is None:
        reset = budget.get("reset_at")
    reset_seconds = _reset_seconds(reset)
    action, live_status, predictive = _limit_action(used, signal.get("limit_signal"), reset_seconds, policy,
                                                     fallback_available, last_status)
    # Non-exact sources are never allowed to carry money into the canonical
    # snapshot, even if an adapter accidentally returned a numeric value.
    exact = budget.get("status") in {"known", "limited"} and budget.get("remaining") is not None and \
            source_class in {"official-api", "official-cli"} and provider.get("budget_exact") is True
    budget = {"status": budget.get("status", "unknown"),
              "remaining": budget.get("remaining") if exact else None,
              "currency": budget.get("currency") if exact else None,
              "reset_at": budget.get("reset_at") if exact and source_class in {"official-api", "official-cli"} else None,
              "exact": bool(exact)}
    limitations = list(provider.get("limits_limitations", []))
    state_blocking = _state_is_blocking(state)
    routing_state = str(state.get("last_status", "unknown")) if state else "unknown"
    if routing_state not in STATE_STATUSES:
        routing_state = "unknown"
    if state_blocking:
        live_status = "exhausted" if routing_state == "exhausted" else "limited"
        action = "handoff"
        limitations.append(f"persistent routing state={routing_state}; next probe is required before reuse")
    operator_remaining = (state.get("operator_budget_remaining") if state and state.get("operator_budget_remaining") is not None
                          else provider.get("operator_budget_usd"))
    operator_estimate = {"remaining": operator_remaining, "currency": "USD" if operator_remaining is not None else None,
                         "label": "operator-estimate", "scope": provider.get("operator_budget_scope", "estimate-only") if operator_remaining is not None else "unknown"}
    if model_catalog["status"] == "available":
        limitations.append(f"official OpenRouter model catalog matched {model_catalog['requested_model']}")
    elif model_catalog["status"] == "model_unavailable":
        limitations.append("requested model is absent from the OpenRouter catalog")
        live_status = "unknown"
        action = "unknown"
        predictive = False
    if not predictive:
        limitations.append("no fresh machine-readable quota signal")
    if source_class == "official-dashboard":
        limitations.append("dashboard-only source; exact balance is unknown")
    if budget.get("remaining") is None:
        limitations.append("exact balance is null unless an official exact source proves it")
    if isinstance(used, (int, float)) and 0 < used < float(policy["handoff_threshold_pct"]):
        if used >= float(policy["warning_threshold_pct"]):
            limitations.append("warning threshold reached; supervisor continues without handoff")
    snapshot = {
        "schema_version": "parallax-provider-limits-v1", "provider": name,
        "upstream_provider": None, "upstream_model": None, "balance_scope": "unknown",
        "routing": {"only": [], "order": [], "allow_fallbacks": True, "model_fallbacks": [], "data_retention_policy": None},
        "routing_state": "stale", "operator_estimate": {"remaining": None, "currency": None, "label": "operator-estimate", "scope": "unknown"},
        "upstream_provider": (provider.get("upstream_provider") or
                              (_routing_config(provider).get("only") or [None])[0]
                              if provider.get("transport") == "openrouter-api" else None),
        "upstream_model": provider.get("model") if provider.get("transport") == "openrouter-api" else None,
        "balance_scope": str(budget_scope or provider.get("balance_scope") or
                              ("openrouter-key" if provider.get("transport") == "openrouter-api" and budget.get("remaining") is not None else "unknown")),
        "routing_state": routing_state,
        "operator_estimate": operator_estimate,
        "routing": {
            "only": list(_routing_config(provider).get("only", [])),
            "order": list(_routing_config(provider).get("order", [])),
            "allow_fallbacks": bool(_routing_config(provider).get("allow_fallbacks", True)),
            "model_fallbacks": list(_routing_config(provider).get("models", provider.get("models", []))),
            "data_retention_policy": _routing_config(provider).get("data_retention_policy")
        },
        "configured": bool(report.get("configured")),
        "authenticated": report.get("authenticated", "unknown"),
        "available": "yes" if report.get("command_available") else "no",
        "plan": {"name": provider.get("plan_name") or signal.get("plan"),
                 "source": str(provider.get("limits_plan_source") or source_class)},
        "budget": budget,
        "model_catalog": model_catalog,
        "quota": {"used_percentage": used if isinstance(used, (int, float)) else None,
                  "remaining_percentage": (100.0 - float(used)) if isinstance(used, (int, float)) and 0 <= used <= 100 else None,
                  "window": signal.get("window"), "reset_at": reset if isinstance(reset, str) else None},
        "live_signal": live_status, "action": action, "source_class": source_class,
        "confidence": "high" if predictive and source_class in {"official-api", "official-cli"} else ("medium" if predictive else "low"),
        "stale": False, "observed_at": signal.get("observed_at") or now(),
        "limitations": sorted(set(str(x)[:240] for x in limitations)),
    }
    state_store.close()
    age = _snapshot_age_seconds(snapshot["observed_at"])
    snapshot["stale"] = age is None or age > float(policy["stale_ttl_s"])
    if snapshot["stale"]:
        snapshot["live_signal"] = "unknown"
        snapshot["action"] = "unknown"
        snapshot["confidence"] = "low"
        snapshot["limitations"].append("snapshot is stale and cannot prove a healthy limit")
    if previous and not signal and previous.get("schema_version") == "parallax-provider-limits-v1":
        # Retain a prior point-in-time signal only until its provider TTL.  The
        # observed timestamp is not refreshed when no new signal was collected.
        snapshot = dict(previous)
        age = _snapshot_age_seconds(snapshot.get("observed_at"))
        snapshot["stale"] = age is None or age > float(policy["stale_ttl_s"])
        if snapshot["stale"]:
            snapshot["live_signal"] = "unknown"
            snapshot["action"] = "unknown"
            snapshot["confidence"] = "low"
            snapshot["limitations"] = sorted(set(snapshot.get("limitations", []) + ["snapshot is stale and cannot prove a healthy limit"]))
    _schema_validate(snapshot, LIMITS_SCHEMA)
    return snapshot


def _previous_snapshot(runtime: Path) -> dict[str, Any] | None:
    path = runtime / "limits.snapshot.json"
    try:
        value = _json(path)
        if isinstance(value, dict) and value.get("schema_version") == "parallax-provider-limits-v1":
            return value
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    return None


def refresh_limits_context(request: dict[str, Any], registry: dict[str, Any], provider_name: str,
                           *, boundary: str, fallback_available: bool = False,
                           last_status: str | None = None) -> dict[str, Any]:
    provider = registry.get("providers", {}).get(provider_name)
    if not isinstance(provider, dict):
        raise ValueError(f"unknown provider {provider_name!r}")
    runtime = _runtime_dir(request)
    previous = _previous_snapshot(runtime)
    snapshot = _snapshot_for_provider(Path(request.get("repo", request.get("worktree", "."))).resolve(), provider_name,
                                      provider, registry, request, fallback_available=fallback_available,
                                      last_status=last_status, previous=previous,
                                      probe_budget=bool(request.get("_limits_probe_budget", False)))
    runtime.mkdir(parents=True, exist_ok=True)
    _ensure_runtime_excluded(Path(request.get("worktree", request.get("repo", "."))).resolve(), runtime)
    snapshot_path = runtime / "limits.snapshot.json"
    context_path = runtime / "limits.context.md"
    snapshot_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    context_path.write_text(_snapshot_context(snapshot), encoding="utf-8")
    request["limits_snapshot_path"] = str(snapshot_path)
    request["limits_context_path"] = str(context_path)
    request["limits_snapshot"] = snapshot
    request["limits_runtime_dir"] = str(runtime)
    request["_limits_hashes"] = {str(snapshot_path): hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
                                  str(context_path): hashlib.sha256(context_path.read_bytes()).hexdigest()}
    request["_limits_boundary"] = boundary
    return snapshot


def collect_limits(repo: Path, config: Path | None, provider_name: str | None = None, *,
                   probe_auth: bool = False, probe_all: bool = False, probe_budget: bool = False) -> list[dict[str, Any]]:
    registry, _ = load_registry(repo, config)
    names = list(registry["providers"])
    if provider_name:
        canonical = PROVIDER_ALIASES.get(provider_name, provider_name)
        if canonical not in registry["providers"]:
            raise ValueError(f"unknown provider {provider_name!r}")
        names = [canonical]
    request = {"repo": str(repo), "worktree": str(repo), "slug": "limits"}
    snapshots = []
    for name in names:
        provider = registry["providers"][name]
        snapshot = _snapshot_for_provider(repo, name, provider, registry, request,
                                           probe_auth=probe_auth, probe_all=probe_all, probe_budget=probe_budget,
                                           previous=None)
        snapshots.append(snapshot)
        if probe_auth or probe_all or probe_budget:
            _record_successful_probe(repo, name, provider, registry, snapshot)
    return snapshots


def _reset_seconds(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        stamp = value.replace("Z", "+00:00")
        from datetime import datetime
        target = datetime.fromisoformat(stamp).timestamp()
        delta = target - time.time()
        return delta if delta > 0 else None
    except (TypeError, ValueError, OverflowError):
        return None


def limit_guard(provider: dict[str, Any], request: dict[str, Any], boundary: str,
                fallback_available: bool, last_status: str | None = None) -> dict[str, Any]:
    """Observe a configured live signal at a safe boundary.

    This function never kills a child process. It is called before dispatch,
    after a child returns, before commit, and before fallback. A native host
    turn can only be classified after the host exposes an observation.
    """
    signal = _read_live_signal(provider, request)
    signal_present = bool(signal)
    signal.setdefault("source_class", provider.get("live_signal_source_class", "unknown"))
    signal.setdefault("observed_at", now())
    used = signal.get("used_percentage")
    reset_seconds = _reset_seconds(signal.get("resets_at"))
    registry = request.get("limits_registry") if isinstance(request.get("limits_registry"), dict) else {}
    policy = _limits_policy(registry, provider)
    action, live_status, predictive = _limit_action(used, signal.get("limit_signal"), reset_seconds, policy,
                                                     fallback_available, last_status)
    if not signal_present and action == "continue":
        predictive = False
    jitter = min(float(policy.get("reset_jitter_s", 30)), 300.0)
    sleep_seconds = None
    if action == "sleep_until_reset" and reset_seconds is not None:
        sleep_seconds = min(reset_seconds, float(policy.get("max_sleep_s", 3600))) + random.SystemRandom().uniform(0, jitter)
    return {"action": action, "boundary": boundary, "live_status": live_status,
            "predictive": predictive, "observed_at": signal.get("observed_at"),
            "source_class": signal.get("source_class", "unknown"), "used_percentage": used,
            "resets_at": signal.get("resets_at"), "reset_seconds": reset_seconds,
            "authenticated": signal.get("authenticated", "unknown"), "available": signal.get("available", "unknown"),
            "sleep_seconds": sleep_seconds}


def _provider_command(provider: dict[str, Any], request: dict[str, Any], prompt_file: Path) -> list[str]:
    command = provider.get("command")
    if not command:
        raise ValueError("provider has no command")
    argv = shlex.split(str(command))
    transport = provider.get("transport")
    model = str(provider.get("model", ""))
    if isinstance(provider.get("args"), list):
        extra = [str(x).format(model=model, worktree=request["worktree"], prompt_file=str(prompt_file)) for x in provider["args"]]
        return argv + extra
    if transport == "codex-cli":
        out = argv + ["exec", "--json", "--sandbox", str(provider.get("sandbox", "workspace-write"))]
        if model:
            out += ["--model", model]
        if provider.get("reasoning_effort"):
            out += ["--reasoning-effort", str(provider["reasoning_effort"])]
        return out + ["-"]
    if transport in {"aider-api", "openrouter-api"}:
        if transport == "openrouter-api" and provider.get("key_env") != "OPENROUTER_API_KEY":
            raise ValueError("openrouter-api requires OPENROUTER_API_KEY and cannot use ZAI_API_KEY")
        out = argv + ["--yes-always", "--no-auto-commits"]
        if model:
            if transport == "openrouter-api":
                version = _aider_version(request, provider, argv)
                if version < (0, 40, 0):
                    raise ValueError("unsupported_openrouter_invocation")
                model = model if model.startswith("openrouter/") else "openrouter/" + model
            out += ["--model", model]
        if provider.get("base_url") and transport != "openrouter-api":
            out += ["--openai-api-base", str(provider["base_url"])]
        manifest = _read_manifest(request)
        context_path = request.get("limits_context_path")
        context_arg = str(context_path) if context_path else None
        if context_path:
            try:
                context_arg = str(Path(str(context_path)).resolve().relative_to(Path(request["worktree"]).resolve()))
            except (KeyError, ValueError):
                context_arg = str(context_path)
        if context_arg and context_arg not in manifest["visible_files"]:
            # This is one generated control artifact, never a directory or a
            # telemetry bundle.  The caller still owns the visibility manifest.
            out += ["--read", context_arg]
        for path in manifest["visible_files"]:
            out += ["--read", path]
        for path in manifest["writable_files"]:
            out += ["--file", path]
        return out
    if transport == "native-claude":
        raise ValueError("native-claude requires the Claude host Task dispatcher")
    raise ValueError(f"unsupported provider transport: {transport}")


def _worker_prompt(request: dict[str, Any]) -> str:
    prompt = str(request.get("prompt", ""))
    context_path = request.get("limits_context_path")
    if not context_path:
        return prompt
    try:
        context = Path(str(context_path)).read_text(encoding="utf-8")
    except OSError:
        context = ""
    # Codex receives a fixed prefix; native Claude dispatchers can use the same
    # request fields, while Aider receives the exact file as --read above.
    if context:
        return context.rstrip() + "\n\n[PARALLAX_TASK]\n" + prompt
    return prompt


def _runtime_expected_paths(request: dict[str, Any]) -> dict[Path, str]:
    values = request.get("_limits_hashes", {})
    return {Path(str(path)).resolve(): str(digest) for path, digest in values.items()}


def _runtime_mutated(request: dict[str, Any]) -> bool:
    for path, expected in _runtime_expected_paths(request).items():
        try:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            return True
        if actual != expected:
            return True
    return False


def _worker_status_paths(request: dict[str, Any]) -> list[str]:
    worktree = Path(request["worktree"]).resolve()
    paths = _status_paths(worktree)
    expected = set(_runtime_expected_paths(request))
    filtered = []
    for rel in paths:
        absolute = (worktree / rel).resolve()
        if absolute in expected and not _runtime_mutated(request):
            continue
        filtered.append(rel)
    return filtered


def _reconcile_disposable(request: dict[str, Any], worktree: Path) -> tuple[bool, str | None]:
    """Reset the final failed attempt to clean_base, preserving control runtime files."""
    if not request.get("disposable_worktree"):
        return True, None
    base = request.get("clean_base")
    if not base:
        return False, "partial-edit-not-reconciled"
    try:
        _git(worktree, "reset", "--hard", str(base), check=True)
        runtime = _runtime_dir(request)
        clean_args = ["clean", "-fd"]
        try:
            rel = runtime.relative_to(worktree)
            clean_args.extend(["-e", str(rel)])
        except ValueError:
            pass
        _git(worktree, *clean_args, check=True)
        if _git(worktree, "rev-parse", "HEAD").stdout.strip() != str(base):
            return False, "partial-edit-not-reconciled"
        if _worker_status_paths(request):
            return False, "partial-edit-not-reconciled"
        return True, None
    except Exception:
        return False, "partial-edit-not-reconciled"


def _write_attempt_artifacts(request: dict[str, Any], attempt: int, stdout: str, stderr: str, env: dict[str, str]) -> list[str]:
    root = request.get("attempt_artifacts")
    if not root:
        return []
    directory = Path(root)
    directory.mkdir(parents=True, exist_ok=True)
    stem = f"{request.get('slice_id', 'slice')}.attempt{attempt}"
    events = directory / f"{stem}.events.jsonl"
    final = directory / f"{stem}.final.txt"
    events.write_text(_redact(stdout, env), encoding="utf-8")
    final.write_text(_redact(stderr or stdout, env)[-100_000:], encoding="utf-8")
    return [str(events), str(final)]


def run_attempt(request: dict[str, Any], provider_name: str, provider: dict[str, Any], attempt: int, host: str,
                fallback_available: bool = False) -> dict[str, Any]:
    worktree = Path(request["worktree"]).resolve()
    branch = request.get("expected_branch")
    manifest = _read_manifest(request)
    if not worktree.exists() or _git(worktree, "rev-parse", "--git-dir").returncode != 0:
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "invalid-worktree", [], None)
    if branch and _git(worktree, "symbolic-ref", "--short", "HEAD").stdout.strip() != branch:
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "wrong-branch", [], None)
    before = _git(worktree, "rev-parse", "HEAD").stdout.strip()
    if _worker_status_paths(request):
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "dirty-base", [], None)
    clean, reason = _blindfold(request, worktree)
    if not clean:
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, reason, [], None)
    try:
        refresh_limits_context(request, request.get("limits_registry", {}), provider_name,
                               boundary="before_request", fallback_available=fallback_available)
    except (OSError, ValueError, RuntimeError):
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None,
                        "limits-context-unavailable", [], None)
    pre_guard = limit_guard(provider, request, "before_request", fallback_available)
    if pre_guard["action"] != "continue":
        return _attempt(request, provider_name, provider, attempt, host,
                        "limit" if pre_guard["action"] == "handoff" else "parked", branch, None,
                        "limit-guard-" + pre_guard["action"], [], None, limit_observation=pre_guard,
                        limit_action=pre_guard["action"])
    for required_path in (request.get("spec_path"), request.get("validation_path")):
        if required_path and not Path(required_path).exists():
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "missing-frozen-artifact", [], None)
    prompt = _worker_prompt(request)
    key_env_name = provider.get("key_env")
    if not prompt or (key_env_name and key_env_name in prompt):
        return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "unsafe-prompt", [], None)
    with tempfile.NamedTemporaryFile("w", prefix="parallax-prompt-", suffix=".txt", delete=False, encoding="utf-8") as f:
        f.write(prompt)
        prompt_file = Path(f.name)
    env = os.environ.copy()
    for name in {provider.get("credits_key_env"), "OPENROUTER_MANAGEMENT_KEY", "management_key_env"}:
        if name:
            env.pop(str(name), None)
    if provider.get("key_env"):
        secret = discover_secret(Path(request.get("repo", worktree)), provider["key_env"])
        if not secret.get("configured"):
            prompt_file.unlink(missing_ok=True)
            return _attempt(request, provider_name, provider, attempt, host, "auth_error", branch, None, "missing-key", [], None)
        # Values already present in the process are passed through.  Dotenv values are
        # loaded only into the child and are never reflected in a result or prompt.
        if provider["key_env"] not in env:
            for candidate, _ in _env_candidates(Path(request.get("repo", worktree))):
                values = _dotenv(candidate)
                if provider["key_env"] in values:
                    env[provider["key_env"]] = values[provider["key_env"]]
                    break
        if env.get(provider["key_env"]) and env[provider["key_env"]] in prompt:
            prompt_file.unlink(missing_ok=True)
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "secret-in-prompt", [], None)
    env = _aider_child_env(provider, env)
    try:
        cmd = _provider_command(provider, request, prompt_file)
        timeout = float(request.get("timeout_s", provider.get("timeout_s", 600)))
        proc = subprocess.run(cmd, cwd=worktree, input=prompt, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=timeout)
        output = (proc.stdout or "") + "\n" + (proc.stderr or "")
        artifacts = _write_attempt_artifacts(request, attempt, proc.stdout or "", proc.stderr or "", env)
        if BALANCE_RE.search(output) or proc.returncode != 0 or not (proc.stdout or "").strip():
            status, error = _classify(proc.returncode, output)
            return _attempt(request, provider_name, provider, attempt, host, status, branch, None, error, artifacts, proc.returncode)
        if _runtime_mutated(request):
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None,
                            "visibility-manifest-violation", artifacts, proc.returncode)
        try:
            refresh_limits_context(request, request.get("limits_registry", {}), provider_name,
                                   boundary="after_response", fallback_available=fallback_available,
                                   last_status=None)
        except (OSError, ValueError, RuntimeError):
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None,
                            "limits-context-unavailable", artifacts, proc.returncode)
        post_guard = limit_guard(provider, request, "after_response", fallback_available, last_status=None)
        if post_guard["action"] != "continue":
            return _attempt(request, provider_name, provider, attempt, host,
                            "limit" if post_guard["action"] == "handoff" else "parked", branch, None,
                            "limit-guard-" + post_guard["action"], artifacts, proc.returncode,
                            limit_observation=post_guard, limit_action=post_guard["action"])
        after = _git(worktree, "rev-parse", "HEAD").stdout.strip()
        if after != before:
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "provider-committed-outside-protocol", artifacts, proc.returncode)
        changed = _worker_status_paths(request)
        allowed = set(manifest["writable_files"])
        unexpected = [p for p in changed if p not in allowed]
        if unexpected:
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "visibility-manifest-violation", artifacts, proc.returncode)
        gate = request.get("done_gate")
        if gate:
            if not isinstance(gate, list) or not all(isinstance(x, str) for x in gate):
                return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, "invalid-done-gate", artifacts, proc.returncode)
            gate_proc = subprocess.run(gate, cwd=worktree, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=float(request.get("done_gate_timeout_s", 600)))
            if gate_proc.returncode != 0:
                return _attempt(request, provider_name, provider, attempt, host, "provider_error", branch, None, "done-gate-failed", artifacts, proc.returncode)
        try:
            refresh_limits_context(request, request.get("limits_registry", {}), provider_name,
                                   boundary="before_commit", fallback_available=fallback_available,
                                   last_status=None)
        except (OSError, ValueError, RuntimeError):
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None,
                            "limits-context-unavailable", artifacts, proc.returncode)
        before_commit_guard = limit_guard(provider, request, "before_commit", fallback_available, last_status=None)
        if before_commit_guard["action"] != "continue":
            return _attempt(request, provider_name, provider, attempt, host,
                            "limit" if before_commit_guard["action"] == "handoff" else "parked", branch, None,
                            "limit-guard-" + before_commit_guard["action"], artifacts, proc.returncode,
                            limit_observation=before_commit_guard, limit_action=before_commit_guard["action"])
        if not changed:
            return _attempt(request, provider_name, provider, attempt, host, "no_change", branch, None, None, artifacts, proc.returncode,
                            limit_observation=before_commit_guard, limit_action="continue")
        _git(worktree, "add", "--", *changed, check=True)
        message = f"Parallax {request.get('role', 'worker')} {request.get('slice_id', 'slice')} via {provider_name} attempt {attempt}"
        _git(worktree, "commit", "-m", message, check=True)
        commit = _git(worktree, "rev-parse", "HEAD").stdout.strip()
        clean, reason = _blindfold(request, worktree)
        if not clean:
            return _attempt(request, provider_name, provider, attempt, host, "parked", branch, None, reason, artifacts, proc.returncode)
        return _attempt(request, provider_name, provider, attempt, host, "committed", branch, commit, None, artifacts, proc.returncode,
                        limit_observation=before_commit_guard, limit_action="continue")
    except subprocess.TimeoutExpired:
        return _attempt(request, provider_name, provider, attempt, host, "timeout", branch, None, "timeout", [], None)
    except (OSError, ValueError, RuntimeError) as exc:
        # Do not expose command lines, stderr, or exception text: they may carry secrets.
        error = "provider-error" if not isinstance(exc, ValueError) else (
            str(exc) if str(exc) in {"aider_missing", "unsupported_openrouter_invocation"}
            else "invalid-provider-config")
        return _attempt(request, provider_name, provider, attempt, host, "provider_error", branch, None, error, [], None)
    finally:
        prompt_file.unlink(missing_ok=True)


def _attempt(request: dict[str, Any], provider: str, config: dict[str, Any], attempt: int, host: str,
             status: str, branch: str | None, commit: str | None, error: str | None,
             artifacts: list[str], returncode: int | None, limit_observation: dict[str, Any] | None = None,
             limit_action: str | None = None) -> dict[str, Any]:
    logical_model = config.get("logical_model") or (str(config.get("model")).split("/", 1)[-1] if config.get("transport") == "openrouter-api" else config.get("model"))
    result = {"schema_version": "parallax-worker-attempt-v1", "host": host, "provider": provider,
              "transport": config.get("transport"), "model": logical_model, "role": request.get("role"),
              "slice_id": request.get("slice_id"), "attempt": attempt, "status": status,
              "worktree": str(Path(request.get("worktree", "")).resolve()), "branch": branch,
              "commit": commit, "usage": {"input_tokens": None, "output_tokens": None, "cost_usd": None},
              "artifacts": artifacts, "error_class": error, "exit_class": error or ("zero" if returncode == 0 else "nonzero")}
    if config.get("transport") == "openrouter-api":
        routing = _routing_config(config)
        result.update({"upstream_provider": (routing.get("only") or [None])[0],
                       "upstream_model": config.get("model"),
                       "balance_scope": config.get("balance_scope", "openrouter-key"),
                       "routing": {"only": list(routing.get("only", [])), "order": list(routing.get("order", [])),
                                   "allow_fallbacks": bool(routing.get("allow_fallbacks", True)),
                                   "model_fallbacks": list(routing.get("models", config.get("models", []))),
                                   "data_retention_policy": routing.get("data_retention_policy")}})
    if limit_observation is not None:
        result["limit_observation"] = limit_observation
    if limit_action is not None:
        result["limit_action"] = limit_action
    _schema_validate(result, ATTEMPT_SCHEMA)
    return result


def _append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(item, sort_keys=True) + "\n")


def _evidence_event(request: dict[str, Any], result: dict[str, Any]) -> None:
    evidence = request.get("evidence_dir")
    if not evidence:
        return
    cmd = [sys.executable, str(ROOT / "scripts" / "evidence-event.py"), "append", str(evidence),
           "--run-id", str(request.get("run_id", "provider-runtime")), "--slug", str(request.get("slug", "provider-runtime")),
           "--event-type", "provider_attempt", "--actor", str(request.get("role", "external")),
           "--summary", f"{result['role']} attempt {result['attempt']} via {result['provider']} classified {result['status']}",
           "--artifact-paths", json.dumps({"attempt": request.get("attempt_receipt", "")}),
           "--worktree", result["worktree"], "--branch", str(result.get("branch") or ""),
           "--commit", str(result.get("commit") or ""), "--host", result["host"], "--provider", result["provider"],
           "--transport", result["transport"], "--model", str(result.get("model") or ""), "--attempt", str(result["attempt"]),
           "--exit-class", result["exit_class"], "--error-class", str(result.get("error_class") or "")]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _provider_state(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any]) -> tuple[ProviderStateStore, dict[str, Any] | None, dict[str, Any]]:
    return _load_provider_state(repo, name, provider, registry)


def _mark_provider_state(request: dict[str, Any], registry: dict[str, Any], name: str,
                         provider: dict[str, Any], result: dict[str, Any]) -> None:
    store, prior, identity = _provider_state(Path(request.get("repo", request["worktree"])).resolve(), name, provider, registry)
    status = None
    error_class = result.get("error_class")
    if result.get("status") in {"committed", "no_change"}:
        status = "healthy"
    elif result.get("status") == "auth_error":
        status = "auth_failed"
    elif result.get("error_class") == "insufficient_balance" and provider.get("credential_class") == "zai-api":
        status = "exhausted"
    elif result.get("status") == "limit" and error_class in {"limit", "insufficient_balance", "openrouter-budget-exhausted"}:
        status = "rate_limited"
    if status is None:
        store.close()
        return
    observation = result.get("limit_observation") or {}
    reset_at = observation.get("resets_at")
    next_probe = reset_at if status in {"exhausted", "rate_limited"} else None
    operator = prior.get("operator_budget_remaining") if prior else provider.get("operator_budget_usd")
    store.put(provider=identity["provider"], transport=identity["transport"], fingerprint=identity["fingerprint"],
              model=identity["model"], upstream_model=identity["upstream_model"], project_scope=identity["project_scope"],
              status=status, error_class=error_class, provider_code=observation.get("provider_code"),
              reset_at=reset_at, next_probe_at=next_probe,
              source_class=observation.get("source_class") or provider.get("limits_source_class") or
              provider.get("budget_source_class", "unknown"),
              confidence="high" if status == "healthy" else "medium", balance_scope=provider.get("balance_scope", "unknown"),
              remaining=None, operator_budget_remaining=operator, last_probe_ok=status == "healthy")
    store.close()


def _route_chain(request: dict[str, Any], registry: dict[str, Any], chain: list[str]) -> list[str]:
    providers = registry.get("providers", {})
    routed: list[str] = []
    for name in chain:
        if name not in routed:
            routed.append(name)
        provider = providers.get(name)
        if isinstance(provider, dict):
            extras = request.get("model_fallbacks") if name == request.get("primary_provider") else None
            extras = extras or provider.get("fallback_providers", [])
            if isinstance(extras, list):
                for fallback in extras:
                    if fallback in providers and fallback not in routed:
                        routed.append(fallback)
    return routed


def _openrouter_budget_gate(request: dict[str, Any], registry: dict[str, Any], name: str,
                            provider: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    snapshot = _snapshot_for_provider(Path(request.get("repo", request["worktree"])).resolve(), name, provider, registry,
                                      request, fallback_available=True, probe_budget=True, probe_auth=True)
    budget = snapshot["budget"]
    healthy = budget["status"] in {"known", "limited"} and isinstance(budget.get("remaining"), (int, float)) and budget["remaining"] > 0
    if not healthy:
        healthy = snapshot["quota"]["used_percentage"] is not None and snapshot["quota"]["used_percentage"] < 90 and not snapshot["stale"]
    request["_limits_probe_budget"] = True
    if healthy:
        _record_successful_probe(Path(request.get("repo", request["worktree"])).resolve(), name, provider, registry, snapshot)
    return healthy, snapshot


def _record_successful_probe(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any],
                             snapshot: dict[str, Any]) -> None:
    if snapshot.get("stale") or snapshot.get("action") == "unknown":
        return
    if not (snapshot.get("budget", {}).get("exact") or snapshot.get("live_signal") == "healthy"):
        return
    store, prior, identity = _provider_state(repo, name, provider, registry)
    store.put(provider=identity["provider"], transport=identity["transport"], fingerprint=identity["fingerprint"],
              model=identity["model"], upstream_model=identity["upstream_model"], project_scope=identity["project_scope"],
              status="healthy", source_class=snapshot.get("source_class", "unknown"), confidence=snapshot.get("confidence", "low"),
              balance_scope=snapshot.get("balance_scope", "unknown"), remaining=snapshot.get("budget", {}).get("remaining"),
              operator_budget_remaining=(prior.get("operator_budget_remaining") if prior and prior.get("operator_budget_remaining") is not None else provider.get("operator_budget_usd")),
              last_probe_ok=True)
    store.close()


def dispatch(request: dict[str, Any], registry: dict[str, Any], host: str) -> dict[str, Any]:
    registry = _validate_registry_doc(registry)
    if host not in HOSTS:
        raise ValueError(f"unsupported host {host!r}")
    request["limits_registry"] = registry
    role = request.get("role")
    role_key = ROLE_ALIASES.get(role, role)
    role_config = registry.get("roles", {}).get(role_key, {})
    chain = request.get("chain", role_config.get("chain", []))
    if not isinstance(chain, list) or not chain:
        raise ValueError(f"no explicit provider chain for role {role!r}")
    providers = registry.get("providers", {})
    request["primary_provider"] = request.get("primary_provider", chain[0] if chain else None)
    request["chain"] = _route_chain(request, registry, list(chain))
    chain = request["chain"]
    if request.get("recheck"):
        store = ProviderStateStore(_state_path(registry))
        for name in chain:
            store.clear(name)
        store.close()
    attempt_records = Path(request["attempt_log"]) if request.get("attempt_log") else None
    worktree = Path(request["worktree"]).resolve()
    disposable = bool(request.get("disposable_worktree", False))
    results = []
    for idx, name in enumerate(chain, 1):
        fallback_available = idx < len(chain)
        provider = providers.get(name)
        if not isinstance(provider, dict):
            result = _attempt(request, name, {}, idx, host, "parked", request.get("expected_branch"), None, "unknown-provider", [], None)
        else:
            store, state, identity = _provider_state(Path(request.get("repo", worktree)).resolve(), name, provider, registry)
            blocked = _state_is_blocking(state, recheck=bool(request.get("recheck")))
            store.close()
            if blocked:
                result = _attempt(request, name, provider, idx, host, "limit", request.get("expected_branch"), None,
                                  "persistent-exhausted", [], None, limit_action="handoff")
            elif provider.get("transport") == "openrouter-api":
                budget_ok, budget_snapshot = _openrouter_budget_gate(request, registry, name, provider)
                if not budget_ok:
                    error = "openrouter-budget-exhausted" if budget_snapshot["budget"]["status"] in {"known", "limited"} and budget_snapshot["budget"].get("remaining", 0) <= 0 else "openrouter-budget-unavailable"
                    result = _attempt(request, name, provider, idx, host, "limit", request.get("expected_branch"), None,
                                      error, [], None, limit_action="handoff")
                else:
                    result = run_attempt(request, name, provider, idx, host, fallback_available=fallback_available)
            else:
                result = run_attempt(request, name, provider, idx, host, fallback_available=fallback_available)
            _mark_provider_state(request, registry, name, provider, result)
        results.append(result)
        if attempt_records:
            _append_jsonl(attempt_records, result)
            request["attempt_receipt"] = str(attempt_records)
        _evidence_event(request, result)
        if result["status"] == "committed":
            result["fallback_attempts"] = results[:-1]
            return result
        if not fallback_available:
            try:
                refresh_limits_context(request, registry, name, boundary="before_fallback",
                                       fallback_available=False, last_status=result.get("status"))
            except (OSError, ValueError, RuntimeError):
                result["error_class"] = "limits-context-unavailable"
            final_guard = limit_guard(provider or {}, request, "before_fallback", False, last_status=result.get("status"))
            if final_guard["action"] == "sleep_until_reset":
                result["status"] = "parked"
                result["error_class"] = "sleep_until_reset"
                result["limit_action"] = "sleep_until_reset"
                result["limit_observation"] = final_guard
                clean, error = _reconcile_disposable(request, worktree)
                if not clean:
                    result["error_class"] = error
                return {**result, "fallback_attempts": results}
        if idx < len(chain):
            boundary_guard = limit_guard(provider or {}, request, "before_fallback", True, last_status=result.get("status"))
            if boundary_guard["action"] == "sleep_until_reset":
                # A fallback is available, so a trustworthy reset is advisory;
                # handoff remains the safe action and never blocks the next provider.
                result["limit_observation"] = boundary_guard
                result["limit_action"] = "handoff"
            try:
                dirty = _worker_status_paths(request)
                if dirty:
                    if not disposable:
                        parked = _attempt(request, name, provider or {}, idx, host, "parked", request.get("expected_branch"), None,
                                          "partial-edit-not-reconciled", [], None)
                        if attempt_records:
                            _append_jsonl(attempt_records, parked)
                        return {**parked, "fallback_attempts": results}
                    base = request.get("clean_base")
                    if not base:
                        return {**_attempt(request, name, provider or {}, idx, host, "parked", request.get("expected_branch"), None,
                                           "missing-clean-base", [], None), "fallback_attempts": results}
                    clean, error = _reconcile_disposable(request, worktree)
                    if not clean:
                        return {**_attempt(request, name, provider or {}, idx, host, "parked", request.get("expected_branch"), None,
                                           error or "partial-edit-not-reconciled", [], None), "fallback_attempts": results}
                if _git(worktree, "rev-parse", "HEAD").stdout.strip() != str(request.get("clean_base", _git(worktree, "rev-parse", "HEAD").stdout.strip())):
                    return {**_attempt(request, name, provider or {}, idx, host, "parked", request.get("expected_branch"), None,
                                       "clean-base-mismatch", [], None), "fallback_attempts": results}
            except Exception:
                return {**_attempt(request, name, provider or {}, idx, host, "parked", request.get("expected_branch"), None,
                                   "partial-edit-not-reconciled", [], None), "fallback_attempts": results}
    parked = results[-1] if results else _attempt(request, "none", {}, 0, host, "parked", None, None, "empty-chain", [], None)
    parked = {**parked, "status": "parked", "error_class": "all-providers-failed", "fallback_attempts": results}
    clean, error = _reconcile_disposable(request, worktree)
    if not clean:
        parked["error_class"] = error or "partial-edit-not-reconciled"
    elif not disposable and _worker_status_paths(request):
        parked["error_class"] = "partial-edit-not-reconciled"
    if attempt_records:
        _append_jsonl(attempt_records, parked)
    if request.get("evidence_dir"):
        subprocess.run([sys.executable, str(ROOT / "scripts" / "evidence-event.py"), "append", str(request["evidence_dir"]),
                        "--run-id", str(request.get("run_id", "provider-runtime")), "--slug", str(request.get("slug", "provider-runtime")),
                        "--event-type", "run_parked", "--actor", "main", "--summary", f"{role} parked after provider chain exhaustion",
                        "--artifact-paths", json.dumps({"attempt_log": str(attempt_records) if attempt_records else ""})],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return parked


def _unknown_snapshot(repo: Path, name: str, provider: dict[str, Any], registry: dict[str, Any], reason: str) -> dict[str, Any]:
    report = _provider_report(repo, name, provider, registry)
    source = str(provider.get("limits_source_class") or provider.get("budget_source_class") or "unknown")
    if source not in SOURCE_CLASSES:
        source = "unknown"
    snapshot = {
        "schema_version": "parallax-provider-limits-v1", "provider": name,
        "configured": bool(report.get("configured")), "authenticated": report.get("authenticated", "unknown"),
        "available": "yes" if report.get("command_available") else "no",
        "plan": {"name": provider.get("plan_name"), "source": str(provider.get("limits_plan_source") or source)},
        "budget": {"status": "unknown", "remaining": None, "currency": None, "reset_at": None, "exact": False},
        "model_catalog": {"status": "not-probed", "requested_model": provider.get("model"), "models": []},
        "quota": {"used_percentage": None, "remaining_percentage": None, "window": None, "reset_at": None},
        "live_signal": "unknown", "action": "continue" if _limits_policy(registry, provider)["unknown_policy"] == "continue-with-warning" else "unknown",
        "source_class": source, "confidence": "low", "stale": True, "observed_at": now(),
        "limitations": [reason, "stale snapshot cannot prove a healthy limit", "exact balance is null unless an official exact source proves it"],
    }
    _schema_validate(snapshot, LIMITS_SCHEMA)
    return snapshot


def _limit_human(snapshot: dict[str, Any]) -> str:
    def value(item: Any) -> str:
        return "unknown" if item is None else str(item)
    lines = [snapshot["provider"],
             f"  configured: {'yes' if snapshot['configured'] else 'no'}",
             f"  authenticated: {snapshot['authenticated']}",
             f"  plan: {value(snapshot['plan']['name'])}",
             f"  quota: {value(snapshot['quota']['used_percentage']) + '%' if snapshot['quota']['used_percentage'] is not None else 'unknown'}",
             f"  balance: {value(snapshot['budget']['remaining']) if snapshot['budget']['remaining'] is not None else 'unknown'}",
             f"  reset: {value(snapshot['quota']['reset_at'] or snapshot['budget']['reset_at'])}",
             f"  source: {snapshot['source_class']}", f"  confidence: {snapshot['confidence']}",
             f"  observed: {snapshot['observed_at']}", f"  stale: {'yes' if snapshot['stale'] else 'no'}",
             f"  action: {snapshot['action'].upper()}"]
    if snapshot["limitations"]:
        lines.append("  limitations: " + "; ".join(snapshot["limitations"]))
    return "\n".join(lines)


def live_smoke(repo: Path, config: Path | None, provider_name: str, model: str,
               max_output_tokens: int, max_cost_usd: float, confirm_spend: bool) -> dict[str, Any]:
    """Fail-closed paid smoke gate; no provider process starts without hard caps."""
    if not confirm_spend:
        return {"status": "blocked", "error_class": "confirm_spend_required"}
    if max_output_tokens < 1 or max_output_tokens > 32:
        return {"status": "blocked", "error_class": "output_cap_unenforceable"}
    if max_cost_usd <= 0 or max_cost_usd > 0.25:
        return {"status": "blocked", "error_class": "cost_cap_unenforceable"}
    registry, _ = load_registry(repo, config)
    provider = registry.get("providers", {}).get(provider_name)
    if not isinstance(provider, dict):
        return {"status": "blocked", "error_class": "unknown-provider"}
    if provider.get("transport") not in {"aider-api", "openrouter-api"}:
        return {"status": "blocked", "error_class": "unsupported_smoke_transport"}
    if str(provider.get("model")) != model:
        return {"status": "blocked", "error_class": "model_mismatch"}
    available, _ = _command_available(str(provider.get("command", "")))
    if not available:
        return {"status": "blocked", "error_class": "aider_missing"}
    # Aider's generic CLI does not provide a machine-enforced USD ceiling.  A
    # future wrapper must prove both controls in the registry before this path
    # may create a child process; prompt/output limits alone are insufficient.
    if provider.get("smoke_cost_cap_enforced") is not True:
        return {"status": "blocked", "error_class": "cost_cap_unenforceable"}
    if provider.get("smoke_one_attempt_enforced") is not True:
        return {"status": "blocked", "error_class": "one_attempt_policy_unenforceable"}
    with tempfile.TemporaryDirectory(prefix="parallax-live-smoke-") as directory:
        request = {"repo": directory, "worktree": directory, "role": "reviewer", "visibility_manifest": {"visible_files": [], "writable_files": []}}
        prompt = "OK; do not edit files"
        prompt_file = Path(directory) / "prompt.txt"
        prompt_file.write_text(prompt, encoding="utf-8")
        try:
            cmd = _provider_command(provider, request, prompt_file)
        except ValueError as exc:
            return {"status": "blocked", "error_class": str(exc) if str(exc) in {"aider_missing", "unsupported_openrouter_invocation"} else "invalid-provider-config"}
        # The configured wrapper owns the exact max-token/cost flags.  No
        # generic Aider invocation is considered safe merely because it exits.
        if not provider.get("smoke_args"):
            return {"status": "blocked", "error_class": "smoke_capability_missing"}
        return {"status": "blocked", "error_class": "smoke_wrapper_not_implemented", "model": model,
                "provider": provider_name, "attempts": 0, "worktree_disposable": True}


def _print_limits(snapshots: list[dict[str, Any]], provider_selected: bool, as_json: bool) -> None:
    if provider_selected:
        value: Any = snapshots[0]
    else:
        value = {"schema_version": "parallax-provider-limits-v1", "snapshots": snapshots, "observed_at": now()}
    _schema_validate(value, LIMITS_SCHEMA)
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True))
    else:
        print("\n\n".join(_limit_human(snapshot) for snapshot in snapshots))


def limits_command(repo: Path, config: Path | None, provider_name: str | None, *, as_json: bool = False,
                   watch: float | None = None, probe_auth: bool = False, probe_all: bool = False,
                   probe_budget: bool = False, recheck: bool = False) -> int:
    if watch is not None and watch <= 0:
        raise ValueError("--watch interval must be greater than zero")
    selected = provider_name is not None
    if recheck:
        registry, _ = load_registry(repo, config)
        store = ProviderStateStore(_state_path(registry))
        store.clear(PROVIDER_ALIASES.get(provider_name, provider_name) if provider_name else None)
        store.close()
    previous: dict[str, dict[str, Any]] = {}
    while True:
        try:
            snapshots = collect_limits(repo, config, provider_name, probe_auth=probe_auth, probe_all=probe_all,
                                       probe_budget=probe_budget)
            previous = {s["provider"]: s for s in snapshots}
        except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
            # A watch never loses the last known point-in-time snapshot.  It is
            # explicitly stale, and never silently relabelled healthy.
            if not previous:
                raise
            snapshots = []
            for old in previous.values():
                stale = dict(old)
                stale["stale"] = True
                stale["live_signal"] = "unknown"
                stale["action"] = "unknown"
                stale["confidence"] = "low"
                stale["limitations"] = sorted(set(stale.get("limitations", []) + ["collection failed; last snapshot is stale"]))
                snapshots.append(stale)
        _print_limits(snapshots, selected, as_json)
        if watch is None:
            return 0
        try:
            time.sleep(watch)
        except KeyboardInterrupt:
            return 0


def command_main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    for name in ("validate-registry", "preflight", "plan"):
        p = sub.add_parser(name)
        p.add_argument("--repo", default=".")
        p.add_argument("--config", default=None)
        p.add_argument("--output", default=None)
        p.add_argument("--probe-budget", action="store_true", help="run only configured read-only budget adapters; never makes a model request")
        p.add_argument("--probe-auth", action="store_true", help="explicitly run providers that declare a read-only auth probe")
        p.add_argument("--probe-all", action="store_true", help="explicitly run all providers that declare a read-only probe")
    f = sub.add_parser("freeze")
    f.add_argument("--plan", required=True); f.add_argument("--selection", required=True); f.add_argument("--output", required=True)
    d = sub.add_parser("dispatch")
    d.add_argument("--request", required=True); d.add_argument("--registry", required=True); d.add_argument("--host", default="claude-code")
    g = sub.add_parser("limit-guard", help="observe one safe-boundary limit signal and return continue/handoff/sleep_until_reset")
    g.add_argument("--request", required=True); g.add_argument("--registry", required=True); g.add_argument("--provider", required=True)
    g.add_argument("--boundary", default="manual", choices=["before_request", "after_response", "before_commit", "before_fallback", "manual"])
    g.add_argument("--fallback-available", action="store_true")
    g.add_argument("--last-status", default=None)
    g.add_argument("--sleep", action="store_true", help="if action is sleep_until_reset, wait only the bounded reported duration and re-probe")
    for name in ("limits", "limit"):
        l = sub.add_parser(name, help="collect passive provider limits without a model request")
        l.add_argument("provider", nargs="?", help="one provider name (z.ai is accepted as an alias for zai)")
        l.add_argument("--repo", default=".")
        l.add_argument("--config", default=None)
        l.add_argument("--json", action="store_true", dest="as_json", help="emit schema-valid JSON")
        l.add_argument("--watch", type=float, default=None, metavar="SECONDS", help="repeat read-only collection")
        l.add_argument("--probe-auth", action="store_true", help="explicitly run a declared read-only auth probe")
        l.add_argument("--probe-all", action="store_true", help="explicitly run all declared read-only probes")
        l.add_argument("--probe-budget", action="store_true", help="run only configured read-only budget adapters")
        l.add_argument("--recheck", action="store_true", help="clear persistent exhausted/auth state before collection")
    s = sub.add_parser("live-smoke", help="fail-closed one-attempt paid smoke gate")
    s.add_argument("--provider", required=True)
    s.add_argument("--model", required=True)
    s.add_argument("--max-output-tokens", required=True, type=int)
    s.add_argument("--max-cost-usd", required=True, type=float)
    s.add_argument("--confirm-spend", action="store_true")
    s.add_argument("--repo", default=".")
    s.add_argument("--config", default=None)
    args = ap.parse_args(argv)
    try:
        if args.command == "freeze":
            result = freeze_plan(Path(args.plan), Path(args.selection), Path(args.output))
        elif args.command == "dispatch":
            request = _json(Path(args.request))
            repo = Path(request.get("repo", request.get("worktree", "."))).resolve()
            registry, _ = load_registry(repo, Path(args.registry).resolve())
            result = dispatch(request, registry, args.host)
        elif args.command == "limit-guard":
            request = _json(Path(args.request)); registry = tomllib.loads(Path(args.registry).read_text(encoding="utf-8"))
            provider = registry.get("providers", {}).get(args.provider)
            if not isinstance(provider, dict):
                raise ValueError(f"unknown provider {args.provider!r}")
            result = limit_guard(provider, request, args.boundary, args.fallback_available, args.last_status)
            if args.sleep and result["action"] == "sleep_until_reset" and result.get("sleep_seconds") is not None:
                time.sleep(float(result["sleep_seconds"]))
                result["after_sleep"] = limit_guard(provider, request, "after_sleep", args.fallback_available, None)
        elif args.command in {"limits", "limit"}:
            return limits_command(Path(args.repo).resolve(), Path(args.config).resolve() if args.config else None,
                                  args.provider, as_json=args.as_json, watch=args.watch,
                                  probe_auth=args.probe_auth, probe_all=args.probe_all,
                                  probe_budget=args.probe_budget, recheck=args.recheck)
        elif args.command == "live-smoke":
            result = live_smoke(Path(args.repo).resolve(), Path(args.config).resolve() if args.config else None,
                                args.provider, args.model, args.max_output_tokens, args.max_cost_usd,
                                args.confirm_spend)
        else:
            repo = Path(args.repo).resolve(); config = Path(args.config).resolve() if args.config else None
            if args.command == "validate-registry":
                registry, path = load_registry(repo, config); result = {"valid": True, "registry": str(path), "providers": sorted(registry["providers"])}
            elif args.command == "preflight":
                result = preflight(repo, config, probe_budget=args.probe_budget,
                                   probe_auth=args.probe_auth, probe_all=args.probe_all)
            else:
                result = build_plan(repo, config, probe_budget=args.probe_budget,
                                    probe_auth=args.probe_auth, probe_all=args.probe_all)
        if getattr(args, "output", None):
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("status") not in {"parked"} else 2
    except (ValueError, RuntimeError, OSError, json.JSONDecodeError) as exc:
        return fail(str(exc), 3 if isinstance(exc, RuntimeError) and "jsonschema" in str(exc) else 2)


if __name__ == "__main__":
    raise SystemExit(command_main())
