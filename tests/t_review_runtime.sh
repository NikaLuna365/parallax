#!/usr/bin/env bash
set -euo pipefail

PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 - "$PLUGIN" "$TMP" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys

plugin = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("review_runtime", plugin / "scripts/review-runtime.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

repo = tmp / "assembled"
repo.mkdir()
(repo / "src.py").write_text("VALUE = 7\n", encoding="utf-8")
(repo / "tests.txt").write_text("assert VALUE == 7\n", encoding="utf-8")
raw = repo / ".parallax" / "demo" / "reviews" / "S1.round1.raw.json"
verdict = {"verdict": "pass", "findings": []}
provider = {
    "kind": "reviewer", "transport": "review-api", "model": "glm-5.2",
    "base_url": "https://review.invalid/v1/chat/completions", "key_env": "ZAI_API_KEY",
    "capabilities": ["read", "structured_output"], "review_max_tokens": 12000,
}
registry = {"providers": {"zai_reviewer": provider}}
request = {
    "repo": str(repo), "raw_output": str(raw),
    "prompt": "Review the assembled tree and return a review round.",
    "context_files": [{"label": "source", "path": "src.py"}, {"label": "tests", "path": "tests.txt"}],
}
os.environ["ZAI_API_KEY"] = "test-secret"
seen = {}

class Response:
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def read(self, limit=-1): return json.dumps({"choices": [{"message": {"content": json.dumps(verdict)}}]}).encode()

def fake_urlopen(req, timeout):
    body = json.loads(req.data.decode())
    seen["body"] = body
    seen["auth"] = req.get_header("Authorization")
    seen["timeout"] = timeout
    return Response()

mod.urllib.request.urlopen = fake_urlopen
result = mod.run_review(request, registry, "zai_reviewer")
assert result["status"] == "ok"
assert json.loads(raw.read_text(encoding="utf-8")) == verdict
assert (repo / "src.py").read_text(encoding="utf-8") == "VALUE = 7\n"
assert seen["auth"] == "Bearer test-secret"
assert seen["body"]["response_format"] == {"type": "json_object"}
assert seen["body"]["model"] == "glm-5.2"
assert "VALUE = 7" in seen["body"]["messages"][1]["content"]
assert "assert VALUE == 7" in seen["body"]["messages"][1]["content"]

# The provider runtime's real cross-model dispatch must select review-runtime,
# not the worker/Aider path.
sys.path.insert(0, str(plugin / "scripts"))
import provider_runtime
raw.write_text(json.dumps(verdict) + "\n", encoding="utf-8")
dispatch_registry = {
    "provider_state_db": str(tmp / "state.sqlite"),
    "providers": {"zai_reviewer": provider},
    "roles": {"cross_model_verifier": {"chain": ["zai_reviewer"]}},
}
dispatch_request = {
    "repo": str(repo), "worktree": str(repo), "role": "cross_model_verifier",
    "slice_id": "S1", "expected_branch": None,
    "review_request": request, "chain": ["zai_reviewer"],
}
dispatch_result = provider_runtime.dispatch(dispatch_request, dispatch_registry, "codex")
assert dispatch_result["status"] == "no_change"
assert dispatch_result["transport"] == "review-api"
assert dispatch_result["review_verdict"] == "pass"

# A request-level stale chain cannot bypass the registry's safe reviewer role.
dispatch_registry["providers"]["zai"] = {
    "kind": "worker", "transport": "aider-api", "command": "aider",
    "model": "glm-5.2", "key_env": "ZAI_API_KEY", "capabilities": ["read", "write", "shell"],
}
stale_request = dict(dispatch_request, chain=["zai"])
try:
    provider_runtime.dispatch(stale_request, dispatch_registry, "codex")
except ValueError as exc:
    assert "cannot use an Aider transport" in str(exc)
else:
    raise AssertionError("request chain bypassed the read-only verifier guard")

# Concerns are surfaced as a review verdict, not collapsed into an ordinary pass.
verdict = {"verdict": "concerns", "findings": [{
    "severity": "high", "kind": "safety", "spec_ref": "spec#review",
    "where": "src.py:1", "claim": "unsafe", "evidence": "fixture evidence",
}]}
raw.write_text(json.dumps(verdict) + "\n", encoding="utf-8")
concern_result = provider_runtime.dispatch(dispatch_request, dispatch_registry, "codex")
assert concern_result["status"] == "no_change"
assert concern_result["review_verdict"] == "concerns"

# A malformed/schema-invalid response must not replace an existing receipt.
raw.write_text("{\"sentinel\":true}\n", encoding="utf-8")
class BadResponse(Response):
    def read(self, limit=-1):
        return json.dumps({"choices": [{"message": {"content": "not-json"}}]}).encode()
mod.urllib.request.urlopen = lambda req, timeout: BadResponse()
try:
    mod.run_review(request, registry, "zai_reviewer")
except mod.ReviewError as exc:
    assert exc.error_class == "malformed-provider-json"
else:
    raise AssertionError("malformed provider response was accepted")
assert raw.read_text(encoding="utf-8") == "{\"sentinel\":true}\n"

# Registry validation rejects a review transport that can write or shell out.
provider_runtime._validate_registry_doc({"providers": {"review": provider}})
openrouter_provider = dict(provider, base_url="https://openrouter.ai/api/v1/chat/completions",
                           key_env="OPENROUTER_API_KEY", credential_class="openrouter-api-key",
                           budget_key_endpoint="https://openrouter.ai/api/v1/key")
provider_runtime._validate_registry_doc({"providers": {"review": openrouter_provider}})
for unsafe in (
    dict(openrouter_provider, key_env="ZAI_API_KEY", credential_class="zai-api"),
    dict(openrouter_provider, management_key_env="OPENROUTER_MANAGEMENT_KEY"),
):
    try:
        provider_runtime._validate_registry_doc({"providers": {"review": unsafe}})
    except ValueError:
        pass
    else:
        raise AssertionError("unsafe OpenRouter review credentials were accepted")
bad = dict(provider, capabilities=["read", "structured_output", "write"])
try:
    provider_runtime._validate_registry_doc({"providers": {"review": bad}})
except ValueError as exc:
    assert "write or shell" in str(exc)
else:
    raise AssertionError("unsafe review capabilities were accepted")
print("OK")
PY

echo "t_review_runtime OK"
