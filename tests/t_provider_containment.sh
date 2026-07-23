#!/usr/bin/env bash
# TZ v0.41 provider-runtime containment gates (see-it-fail-first).
# Every test here drives the ACTUAL condition through the real dispatch path;
# none greps for an implementation string, and none supplies from the harness
# the property it asserts the runtime provides (§6). Neutering any enforced
# branch in a scratch copy must turn at least one of these red.
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

# ---- shared scratch repo + fake providers --------------------------------
python3 - "$T" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1])
(t/'fake-success').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('src/impl.py').write_text('implemented\\n')\nprint('{\"event\":\"done\"}')\n")
# Markers live OUTSIDE the worktree: a failed disposable attempt is reset with
# `git clean`, which would otherwise erase the very evidence the test asserts.
(t/'fake-limit').write_text(f"#!/usr/bin/env python3\nfrom pathlib import Path\nPath(r'{t}/limited-ran').write_text('x\\n')\nprint('quota exhausted', flush=True)\nraise SystemExit(9)\n")
(t/'fake-recovery').write_text(f"#!/usr/bin/env python3\nfrom pathlib import Path\nPath(r'{t}/recovery-ran').write_text('x\\n')\nPath('src/impl.py').write_text('implemented\\n')\nprint('{{\"event\":\"done\"}}')\n")
for p in (t/'fake-success', t/'fake-limit', t/'fake-recovery'):
    p.chmod(0o755)
PY
REPO="$T/repo"; mkdir -p "$REPO/.parallax" "$REPO/src"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf '*.env\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/src/base.py"
git -C "$REPO" add .; git -C "$REPO" commit -qm base
cat > "$REPO/.parallax/providers.toml" <<EOF
host_provider = "codex"
fallback_policy = "ordered-clean-base"
provider_state_db = "$T/state.sqlite"
[providers.fake]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[roles.blind_coder]
chain = ["fake"]
required_capabilities = ["read", "write"]
automatic_fallback = true
EOF
git -C "$REPO" add .parallax/providers.toml; git -C "$REPO" commit -qm providers
git -C "$REPO" switch -qc feature/demo-S1-code
BASE=$(git -C "$REPO" rev-parse HEAD)
printf 'frozen spec\n' > "$T/spec.md"
printf 'validation\n' > "$T/validation.md"

mkreq(){ # $1=output $2=extra-json-mutation (python expression over dict d)
python3 - "$1" "$REPO" "$BASE" "$T" "$2" <<'PY'
import json, sys
out, repo, base, t, mutation = sys.argv[1:]
d = {'repo': repo, 'role': 'blind-coder', 'slice_id': 'S1', 'slug': 'demo', 'run_id': 'run-1',
     'side': 'code', 'worktree': repo, 'expected_branch': 'feature/demo-S1-code', 'clean_base': base,
     'chain': ['fake'], 'spec_path': t + '/spec.md', 'validation_path': t + '/validation.md',
     'visibility_manifest': {'visible_files': ['src/base.py'], 'writable_files': ['src/impl.py']},
     'prompt': 'Implement the frozen behavior.', 'timeout_s': 20, 'attempt_log': t + '/attempts.jsonl'}
exec(mutation)
json.dump(d, open(out, 'w'))
PY
}

# ---- BW1: a blind-coder dispatch omitting side/slug is PARKED ------------
mkreq "$T/bw1a.json" "del d['side']"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/bw1a.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw1a.out"; then
  fail 'BW1: dispatch without side exited 0'
fi
grep -q '"error_class": "blindfold-request-incomplete"' "$T/bw1a.out" || { cat "$T/bw1a.out"; fail 'BW1: missing side did not park blindfold-request-incomplete'; }
grep -q '"status": "parked"' "$T/bw1a.out" || fail 'BW1: missing side was not parked'
[ ! -e "$REPO/src/impl.py" ] || fail 'BW1: provider ran despite incomplete blindfold request'
mkreq "$T/bw1b.json" "del d['slug']"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/bw1b.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw1b.out"; then
  fail 'BW1: dispatch without slug exited 0'
fi
grep -q '"error_class": "blindfold-request-incomplete"' "$T/bw1b.out" || fail 'BW1: missing slug did not park blindfold-request-incomplete'
[ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ] || fail 'BW1: a commit landed from an incomplete request'

# ---- BW2: a missing blindfold-guard.py parks (never "clean") -------------
NOGUARD="$T/plugin-noguard"
mkdir -p "$NOGUARD"
cp -a "$PLUGIN/scripts" "$PLUGIN/assets" "$NOGUARD/"
rm "$NOGUARD/scripts/blindfold-guard.py"
mkreq "$T/bw2.json" "pass"
if python3 "$NOGUARD/scripts/provider-runtime.py" dispatch --request "$T/bw2.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw2.out"; then
  fail 'BW2: dispatch with missing guard exited 0'
fi
grep -q '"error_class": "blindfold-guard-unavailable"' "$T/bw2.out" || { cat "$T/bw2.out"; fail 'BW2: absent guard was not parked blindfold-guard-unavailable'; }
[ ! -e "$REPO/src/impl.py" ] || fail 'BW2: provider ran with the guard missing from disk'

# ---- BW3: codex-host rejects the same wall-opening requests --------------
if python3 "$PLUGIN/scripts/codex-host.py" --request "$T/bw1a.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw3a.out"; then
  fail 'BW3: codex-host accepted a request without side'
fi
grep -q '"error_class": "blindfold-request-incomplete"' "$T/bw3a.out" || fail 'BW3: codex-host missing-side error class wrong'
if python3 "$PLUGIN/scripts/codex-host.py" --request "$T/bw1b.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw3b.out"; then
  fail 'BW3: codex-host accepted a request without slug'
fi
grep -q '"error_class": "blindfold-request-incomplete"' "$T/bw3b.out" || fail 'BW3: codex-host missing-slug error class wrong'

# ---- BW4: a contaminated worktree still parks blindfold-contaminated -----
mkdir -p "$REPO/tests"
printf 'assert True\n' > "$REPO/tests/test_leak.py"
git -C "$REPO" add tests/test_leak.py; git -C "$REPO" commit -qm leak
LEAK=$(git -C "$REPO" rev-parse HEAD)
mkreq "$T/bw4.json" "d['clean_base'] = '$LEAK'"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/bw4.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/bw4.out"; then
  fail 'BW4: contaminated coder worktree exited 0'
fi
grep -q '"error_class": "blindfold-contaminated"' "$T/bw4.out" || { cat "$T/bw4.out"; fail 'BW4: contamination regression'; }
git -C "$REPO" rm -q tests/test_leak.py; git -C "$REPO" commit -qm clean; BASE=$(git -C "$REPO" rev-parse HEAD)

# ---- RC1: a codex-cli provider can never serve the verifier role ---------
cat > "$T/rc1.toml" <<EOF
host_provider = "codex"
provider_state_db = "$T/state.sqlite"
[providers.codexish]
kind = "both"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
capabilities = ["read", "write", "shell", "structured_output"]
[roles.blind_coder]
chain = ["codexish"]
required_capabilities = ["read", "write"]
EOF
python3 - "$T/rc1-req.json" "$REPO" "$T" <<'PY'
import json, sys
out, repo, t = sys.argv[1:]
json.dump({'repo': repo, 'worktree': repo, 'role': 'cross_model_verifier', 'slice_id': 'S1',
           'expected_branch': None, 'chain': ['codexish'],
           'spec_path': t + '/spec.md', 'validation_path': t + '/validation.md',
           'visibility_manifest': {'visible_files': [], 'writable_files': []},
           'prompt': 'review the assembled tree',
           'review_request': {'raw_output': repo + '/.parallax/demo/reviews/S1.round1.raw.json',
                              'prompt': 'review', 'context_files': []}}, open(out, 'w'))
PY
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/rc1-req.json" --registry "$T/rc1.toml" --host codex > "$T/rc1.out"; then
  fail 'RC1: verifier role on codex-cli exited 0'
fi
grep -q '"error_class": "unsafe-provider-chain"' "$T/rc1.out" || { cat "$T/rc1.out"; fail 'RC1: verifier on codex-cli was not parked unsafe-provider-chain'; }
grep -q '"status": "parked"' "$T/rc1.out" || fail 'RC1: verifier on codex-cli was not parked'
[ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ] || fail 'RC1: verifier-role dispatch committed to the worktree'
[ ! -e "$REPO/src/impl.py" ] || fail 'RC1: verifier-role dispatch wrote a candidate file'

# ---- RC2: a write/shell provider in a declared verifier chain fails every entrypoint
cat > "$T/rc2.toml" <<EOF
host_provider = "codex"
provider_state_db = "$T/state.sqlite"
[providers.codexish]
kind = "both"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
capabilities = ["read", "write", "shell", "structured_output"]
[roles.cross_model_verifier]
chain = ["codexish"]
required_capabilities = ["read", "structured_output"]
EOF
for CMD in validate-registry preflight plan; do
  if python3 "$PLUGIN/scripts/provider-runtime.py" "$CMD" --repo "$REPO" --config "$T/rc2.toml" > "$T/rc2-$CMD.out" 2>&1; then
    fail "RC2: $CMD accepted a write/shell provider in the verifier chain"
  fi
done
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/rc1-req.json" --registry "$T/rc2.toml" --host codex > "$T/rc2-dispatch.out" 2>&1; then
  fail 'RC2: dispatch accepted a write/shell provider in the verifier chain'
fi
if python3 "$PLUGIN/scripts/codex-host.py" --request "$T/rc1-req.json" --registry "$T/rc2.toml" --host codex > "$T/rc2-host.out" 2>&1; then
  fail 'RC2: codex-host accepted a write/shell provider in the verifier chain'
fi
grep -q 'unsafe-provider-chain' "$T/rc2-host.out" || fail 'RC2: codex-host error class is not unsafe-provider-chain'
# freeze: a plan whose verifier chain names a write/shell provider cannot freeze
python3 - "$PLUGIN" "$T" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
import provider_runtime as r
t = Path(sys.argv[2])
plan = {"schema_version": "parallax-provider-plan-v1", "created_at": r.now(), "host_provider": "codex",
        "registry": "x", "confirmation_required": True, "fallback_policy": "ordered-clean-base",
        "roles": {"cross_model_verifier": {"chain": ["codexish"], "required_capabilities": ["read", "structured_output"], "automatic_fallback": True}},
        "providers": [{"provider": "codexish", "kind": "both", "transport": "codex-cli", "model": "m",
                        "base_url": None, "capabilities": ["read", "write", "shell", "structured_output"], "configured": True}],
        "budgets": []}
(t / 'rc2-plan.json').write_text(json.dumps(plan))
(t / 'rc2-selection.json').write_text(json.dumps({"confirmed": True, "roles": {"cross_model_verifier": {"chain": ["codexish"]}}}))
try:
    r.freeze_plan(t / 'rc2-plan.json', t / 'rc2-selection.json', t / 'rc2-frozen.json')
except ValueError as exc:
    assert 'unsafe-provider-chain' in str(exc), exc
else:
    raise AssertionError('RC2: freeze accepted a write/shell provider in the verifier chain')
# capability coverage is also enforced for worker roles at freeze
plan['roles'] = {"blind_coder": {"chain": ["codexish"], "required_capabilities": ["read", "write"], "automatic_fallback": True}}
plan['providers'][0]['capabilities'] = ["read"]
(t / 'rc2-plan2.json').write_text(json.dumps(plan))
(t / 'rc2-selection2.json').write_text(json.dumps({"confirmed": True, "roles": {"blind_coder": {"chain": ["codexish"]}}}))
try:
    r.freeze_plan(t / 'rc2-plan2.json', t / 'rc2-selection2.json', t / 'rc2-frozen2.json')
except ValueError as exc:
    assert 'unsafe-provider-chain' in str(exc), exc
else:
    raise AssertionError('RC2: freeze accepted a provider not covering required_capabilities')
PY

# ---- RC3 + CS1/CS-identical + PF: driven through mocked reviewer transport
python3 - "$PLUGIN" "$T" <<'PY'
import importlib.util, json, sys
from pathlib import Path
plugin, t = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(plugin / 'scripts'))
import provider_runtime
spec = importlib.util.spec_from_file_location("review_runtime", plugin / "scripts/review-runtime.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
import os
os.environ['ZAI_API_KEY'] = 'test-secret'

repo = t / 'reviewer-repo'
repo.mkdir()
(repo / 'src.py').write_text('VALUE = 7\n')
raw = repo / '.parallax' / 'demo' / 'reviews' / 'S1.round1.raw.json'
provider = {"kind": "reviewer", "transport": "review-api", "model": "glm-5.2",
            "base_url": "https://review.invalid/v1/chat/completions", "key_env": "ZAI_API_KEY",
            "capabilities": ["read", "structured_output"], "review_max_tokens": 8192,
            "review_timeout_s": 600, "review_thinking": "disabled", "review_thinking_supported": True}
provider_b = dict(provider)
registry = {"provider_state_db": str(t / 'state.sqlite'),
            "providers": {"r1": provider, "r2": provider_b},
            "roles": {"cross_model_verifier": {"chain": ["r1", "r2"]}}}
review_request = {"repo": str(repo), "raw_output": str(raw), "prompt": "Review the tree.",
                  "context_files": [{"label": "source", "path": "src.py"}]}
request = {"repo": str(repo), "worktree": str(repo), "role": "cross_model_verifier",
           "slice_id": "S1", "expected_branch": None, "review_request": review_request,
           "chain": ["r1", "r2"]}

calls = []
class Resp:
    headers = {}
    payload = {}
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self, limit=-1): return json.dumps(self.payload).encode()

def urlopen_factory(payload):
    def fake(req, timeout):
        calls.append(json.loads(req.data.decode()))
        resp = Resp(); resp.payload = payload
        return resp
    return fake

# RC3: a null verdict is a provider failure — never a success status, no
# receipt written, and (being a paid 200) never silently retried either.
mod.urllib.request.urlopen = urlopen_factory({"choices": [{"finish_reason": "stop",
    "message": {"content": json.dumps({"verdict": None, "findings": []})}}],
    "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}})
result = provider_runtime.dispatch(dict(request), registry, "codex")
assert result["status"] not in {"no_change", "committed"}, result["status"]
assert result["error_class"] == "schema-invalid", result["error_class"]
assert len(calls) == 1, f"RC3: null-verdict paid response was retried ({len(calls)} calls)"
assert not raw.exists(), "RC3: a null-verdict response produced a raw receipt"
assert result.get("review_verdict") is None
assert all(a.get("review_verdict") is None for a in result.get("fallback_attempts", []))

# CS1: a paid reasoning-only HTTP 200 → exactly ONE provider call, chain stops.
calls.clear()
mod.urllib.request.urlopen = urlopen_factory({"choices": [{"finish_reason": "stop",
    "message": {"content": "", "reasoning_content": "private chain of thought"}}],
    "usage": {"prompt_tokens": 100, "completion_tokens": 3000, "total_tokens": 3100}})
result = provider_runtime.dispatch(dict(request), registry, "codex")
assert len(calls) == 1, f"CS1: expected exactly one paid provider call, saw {len(calls)}"
assert result["error_class"] == "reasoning-only-response", result["error_class"]
retry = (result.get("provider_diagnostics") or {}).get("automatic_retry", {})
assert retry.get("allowed") is False and retry.get("policy") == "never"
assert retry.get("usage", {}).get("completion_tokens") == 3000

# CS1b: even under the explicit one-retry policy an IDENTICAL body is refused
# before any network call (r2 has identical model+parameters → identical body).
calls.clear()
retry_registry = json.loads(json.dumps(registry))
retry_registry["roles"]["cross_model_verifier"]["paid_retry_policy"] = "one-changed-body"
result = provider_runtime.dispatch(dict(request), retry_registry, "codex")
assert len(calls) == 1, f"CS1b: identical retry reached the provider ({len(calls)} calls)"
attempts = result.get("fallback_attempts", []) + [result]
classes = [a.get("error_class") for a in attempts]
assert "identical-retry-forbidden" in classes, classes

# CS1c: the one-retry policy with a CHANGED body is allowed exactly once and
# the retry records prior error class, usage, and changed parameters.
calls.clear()
changed_registry = json.loads(json.dumps(retry_registry))
changed_registry["providers"]["r2"]["review_max_tokens"] = 4096
changed_registry["providers"]["r2"]["model"] = "glm-5.2-air"
result = provider_runtime.dispatch(dict(request), changed_registry, "codex")
assert len(calls) == 2, f"CS1c: changed-body policy retry did not run ({len(calls)} calls)"
second = result if result.get("provider_diagnostics") else result["fallback_attempts"][-1]
retry_record = (second.get("provider_diagnostics") or {}).get("retry") or {}
assert retry_record.get("prior_error_class") == "reasoning-only-response"
assert retry_record.get("prior_usage", {}).get("completion_tokens") == 3000
assert "model" in retry_record.get("changed_parameters", []), retry_record
assert "missing usage" or True

# Missing usage is unknown, never zero: an HTTP-200 failure without usage still
# stops the chain under the default policy.
calls.clear()
mod.urllib.request.urlopen = urlopen_factory({"choices": [{"finish_reason": "stop",
    "message": {"content": "", "reasoning_content": "x"}}]})
result = provider_runtime.dispatch(dict(request), registry, "codex")
assert len(calls) == 1, "unknown-usage paid failure was retried"
retry = (result.get("provider_diagnostics") or {}).get("automatic_retry", {})
assert retry.get("usage", {}).get("completion_tokens") == "unknown", retry

# A pure transport failure (no HTTP-200 body) still falls through the chain.
calls.clear()
def connect_error(req, timeout):
    calls.append(1)
    raise __import__("urllib.error", fromlist=["URLError"]).URLError("dns")
mod.urllib.request.urlopen = connect_error
result = provider_runtime.dispatch(dict(request), registry, "codex")
assert len(calls) == 2, f"transport failure must still allow fallback ({len(calls)} calls)"

# PF1: a pre_freeze round validates against spec-adversary.schema.json …
adversary = {"verdict": "concerns", "findings": [{"severity": "high", "kind": "spec-gap",
             "where": "B1", "detail": "observable divergence"}]}
mod.urllib.request.urlopen = urlopen_factory({"choices": [{"finish_reason": "stop",
    "message": {"content": json.dumps(adversary)}}],
    "usage": {"prompt_tokens": 5, "completion_tokens": 9, "total_tokens": 14}})
pre_request = dict(review_request, insertion_point="pre_freeze")
ok = mod.run_review(pre_request, registry, "r1")
assert ok["status"] == "ok" and ok["verdict"]["verdict"] == "concerns"
assert json.loads(raw.read_text()) == adversary
schema_prompt = calls[-1]["messages"][1]["content"] if calls else ""
(t / 'pf-raw.json').write_text(json.dumps(adversary))

# … and a post_green round still pins review-round.schema.json: the same
# spec-adversary shape must now FAIL schema validation (fields differ).
raw.unlink()
try:
    mod.run_review(dict(review_request, insertion_point="post_green"), registry, "r1")
except mod.ReviewError as exc:
    assert exc.error_class == "schema-invalid", exc.error_class
else:
    raise AssertionError("PF2: spec-adversary shape passed the post_green schema")
assert not raw.exists()
# an unknown insertion point fails closed
try:
    mod.run_review(dict(review_request, insertion_point="mid_flight"), registry, "r1")
except mod.ReviewError as exc:
    assert exc.error_class == "invalid-insertion-point"
else:
    raise AssertionError("PF: unknown insertion point accepted")

# CS3: fallback_policy="disabled" → _route_chain returns the declared chain unwidened.
wide_registry = {"providers": {"zai": {"transport": "aider-api", "kind": "worker", "command": "x",
                                        "fallback_providers": ["extra"]},
                                "extra": {"transport": "codex-cli", "kind": "worker", "command": "x"}}}
widened = provider_runtime._route_chain({}, {**wide_registry, "fallback_policy": "ordered-clean-base"}, ["zai"])
assert widened == ["zai", "extra"], widened
unwidened = provider_runtime._route_chain({}, {**wide_registry, "fallback_policy": "disabled"}, ["zai"])
assert unwidened == ["zai"], unwidened

# RP1: preflight surfaces the effective reviewer contract with NO network call.
def refuse(req, timeout):
    raise AssertionError("RP1: preflight made a network call")
mod.urllib.request.urlopen = refuse
provider_runtime.urllib.request.urlopen = refuse
pf_repo = t / 'pf-repo'
(pf_repo / '.parallax').mkdir(parents=True)
import subprocess
subprocess.run(['git', 'init', '-q', str(pf_repo)], check=True)
(pf_repo / '.parallax' / 'providers.toml').write_text('''
[providers.zai_reviewer]
kind = "reviewer"
transport = "review-api"
model = "glm-5.2"
base_url = "https://api.z.ai/api/paas/v4/chat/completions"
key_env = "ZAI_API_KEY"
credential_class = "zai-api"
review_timeout_s = 480
review_max_tokens = 4096
review_thinking = "disabled"
review_thinking_supported = true
capabilities = ["read", "structured_output"]
[providers.openrouter_reviewer]
kind = "reviewer"
transport = "review-api"
model = "z-ai/glm-5.2"
base_url = "https://openrouter.ai/api/v1/chat/completions"
key_env = "OPENROUTER_API_KEY"
credential_class = "openrouter-api-key"
capabilities = ["read", "structured_output"]
''')
report = provider_runtime.preflight(pf_repo, None)
contracts = {p['provider']: p.get('review_contract') for p in report['providers']}
zai = contracts['zai_reviewer']
assert zai and zai['model'] == 'glm-5.2' and zai['review_thinking'] == 'disabled'
assert zai['review_max_tokens'] == 4096 and zai['review_timeout_s'] == 480.0
assert zai['endpoint'].startswith('https://api.z.ai') and zai['credential_class'] == 'zai-api'
assert zai['key_present'] is True  # harness exported ZAI_API_KEY above
orc = contracts['openrouter_reviewer']
assert orc and orc['review_max_tokens'] == 8192 and orc['review_timeout_s'] == 600.0
print("reviewer containment OK")
PY

# ---- PF1b: the pre_freeze reviewer round CLOSES the gate: the raw receipt
# recorded above validates as a spec-adversary round and advances rounds_used.
if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  PFDIR="$T/pf-state"; mkdir -p "$PFDIR"
  cp "$PLUGIN/assets/codex/codex.toml.example" "$PFDIR/codex.toml"
  printf 'candidate spec\n' > "$PFDIR/spec.md"; printf 'candidate slices\n' > "$PFDIR/slices.md"
  printf 'candidate validation\n' > "$PFDIR/validation.md"; printf '{"slug":"demo"}\n' > "$PFDIR/slices.lock"
  python3 "$PLUGIN/scripts/pre-freeze-budget.py" record "$PFDIR/pre-freeze-state.json" "$T/pf-raw.json" \
    --policy "$PFDIR/codex.toml" --slug demo --provider zai_reviewer --mode interactive \
    --contract-file "$PFDIR/spec.md" --contract-file "$PFDIR/slices.md" \
    --contract-file "$PFDIR/validation.md" --contract-file "$PFDIR/slices.lock" > "$T/pf-record.out" \
    || { cat "$T/pf-record.out"; fail 'PF1: reviewer pre_freeze round was not accepted by pre-freeze-budget'; }
  python3 - "$PFDIR/pre-freeze-state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state.get('rounds_used') == 1, f"PF1: rounds_used did not advance: {state.get('rounds_used')}"
PY
else
  echo '  · jsonschema not installed - PF1b skipped'
fi

# ---- CS2: automatic_fallback = false is absolute -------------------------
cat > "$T/cs2.toml" <<EOF
host_provider = "codex"
fallback_policy = "ordered-clean-base"
provider_state_db = "$T/cs2-state.sqlite"
[providers.limited]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-limit"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[providers.recovery]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-recovery"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[roles.blind_coder]
chain = ["limited", "recovery"]
required_capabilities = ["read", "write"]
automatic_fallback = false
EOF
git -C "$REPO" reset -q --hard "$BASE"
mkreq "$T/cs2-req.json" "d['chain'] = ['limited', 'recovery']; d.pop('attempt_log', None)"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/cs2-req.json" --registry "$T/cs2.toml" --host codex > "$T/cs2.out"; then
  fail 'CS2: dispatch with automatic_fallback=false exited 0'
fi
[ -e "$T/limited-ran" ] || fail 'CS2: first provider did not run'
[ ! -e "$T/recovery-ran" ] || fail 'CS2: automatic_fallback=false still attempted an alternate provider'
python3 - "$T/cs2.out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert len(r.get('fallback_attempts', [])) <= 1, 'CS2: more than one attempt recorded'
PY
rm -f "$T/limited-ran"; git -C "$REPO" reset -q --hard "$BASE"

# ---- LG1: limit-guard refuses an inline-secret registry ------------------
cat > "$T/lg1a.toml" <<EOF
[providers.zai]
kind = "worker"
transport = "codex-cli"
command = "true"
api_key = "INLINE_SECRET_VALUE_123456"
EOF
printf '{"repo": "%s", "worktree": "%s"}\n' "$REPO" "$REPO" > "$T/lg-req.json"
if python3 "$PLUGIN/scripts/provider-runtime.py" limit-guard --request "$T/lg-req.json" --registry "$T/lg1a.toml" --provider zai > "$T/lg1a.out" 2>&1; then
  fail 'LG1: limit-guard accepted an inline-secret registry'
fi
grep -q 'INLINE_SECRET_VALUE_123456' "$T/lg1a.out" && fail 'LG1: secret echoed in error output'
# value-shaped secrets are rejected even under an innocent key name
cat > "$T/lg1b.toml" <<EOF
[providers.zai]
kind = "worker"
transport = "codex-cli"
command = "true"
authorization = "Bearer sk-live-abcdefghijklmnop"
EOF
if python3 "$PLUGIN/scripts/provider-runtime.py" limit-guard --request "$T/lg-req.json" --registry "$T/lg1b.toml" --provider zai > "$T/lg1b.out" 2>&1; then
  fail 'LG1: limit-guard accepted a Bearer-token value under a non-secret key name'
fi
if python3 "$PLUGIN/scripts/provider-runtime.py" validate-registry --repo "$REPO" --config "$T/lg1b.toml" > /dev/null 2>&1; then
  fail 'LG1: validate-registry accepted a Bearer-token value'
fi

# ---- LG2/LG3: live_signal_command is gated and cannot mint provenance ----
python3 - "$T" <<'PY'
from pathlib import Path
import sys, json
t = Path(sys.argv[1])
(t/'live-signal').write_text("#!/usr/bin/env python3\nimport json, os\nfrom pathlib import Path\nPath(os.environ['LIVE_MARKER']).write_text('ran\\n')\nprint(json.dumps({'used_percentage': 5, 'source_class': 'official-cli', 'authenticated': 'yes'}))\n")
(t/'live-signal').chmod(0o755)
PY
cat > "$T/lg2.toml" <<EOF
probe_policy = "explicit"
provider_state_db = "$T/lg-state.sqlite"
[providers.zai]
kind = "worker"
transport = "codex-cli"
command = "true"
model = "glm-5.2"
key_env = "ZAI_API_KEY"
limits_source_class = "official-dashboard"
live_signal_command = "$T/live-signal"
probe_read_only = true
capabilities = ["read", "write", "shell"]
EOF
export LIVE_MARKER="$T/live-marker"
export ZAI_API_KEY="lg-test-secret"
rm -f "$LIVE_MARKER"
python3 "$PLUGIN/scripts/provider-runtime.py" limits zai --repo "$REPO" --config "$T/lg2.toml" --json > "$T/lg2-passive.json"
[ ! -e "$LIVE_MARKER" ] || fail 'LG2: passive limits executed live_signal_command'
python3 "$PLUGIN/scripts/provider-runtime.py" limits zai --repo "$REPO" --config "$T/lg2.toml" --probe-all --json > "$T/lg2-optin.json"
[ -e "$LIVE_MARKER" ] || fail 'LG2: explicit opt-in did not execute live_signal_command'
python3 - "$T/lg2-optin.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert any('live_signal_command executed' in x for x in d.get('limitations', [])), 'LG2: execution not recorded in evidence'
# LG3: payload said official-cli; the registry declares only official-dashboard,
# so the recorded provenance must not rise above the declaration.
assert d['source_class'] != 'official-cli', d['source_class']
assert d['confidence'] != 'high', d['confidence']
PY
unset LIVE_MARKER ZAI_API_KEY

# ---- CE1: each transport's child holds ONLY its own credential -----------
python3 - "$PLUGIN" "$T" "$REPO" <<'PY'
import json, os, sys
from pathlib import Path
plugin, t, repo = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(plugin / 'scripts'))
import provider_runtime as r
import subprocess

# The harness deliberately floods the environment with credentials — the
# CONDITION. The asserted property (children see only their own) must come
# from the runtime, not from this harness.
os.environ.update({
    'FAKE_KEY': 'fake-secret', 'ZAI_API_KEY': 'zai-secret',
    'OPENROUTER_API_KEY': 'or-secret', 'OPENAI_API_KEY': 'stale-openai',
    'ANTHROPIC_API_KEY': 'stale-anthropic', 'OPENROUTER_MANAGEMENT_KEY': 'mgmt',
})
dump = t / 'env-dump'
dump.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if '--version' in sys.argv:
    print('aider 0.86.2'); raise SystemExit(0)
Path(os.environ['ENV_DUMP_TARGET']).write_text(json.dumps(dict(os.environ)))
print('{\\"event\\":\\"done\\"}')
""")
dump.chmod(0o755)

registry = {"providers": {
    "codexish": {"kind": "worker", "transport": "codex-cli", "command": str(dump), "model": "m",
                  "key_env": "FAKE_KEY", "capabilities": ["read", "write", "shell"]},
    "zai": {"kind": "worker", "transport": "aider-api", "command": str(dump), "model": "glm-5.2",
             "base_url": "https://api.z.ai/api/paas/v4", "key_env": "ZAI_API_KEY",
             "capabilities": ["read", "write", "shell"]},
    "openrouter": {"kind": "worker", "transport": "openrouter-api", "command": str(dump), "model": "z-ai/glm-5.2",
                    "key_env": "OPENROUTER_API_KEY", "capabilities": ["read", "write", "shell"]},
}}
base = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()

def spawn(name):
    target = t / f'env-{name}.json'
    os.environ['ENV_DUMP_TARGET'] = str(target)
    request = {'repo': str(repo), 'role': 'blind-coder', 'slice_id': 'S1', 'slug': 'demo',
               'side': 'code', 'worktree': str(repo), 'expected_branch': 'feature/demo-S1-code',
               'clean_base': base, 'spec_path': str(t / 'spec.md'), 'validation_path': str(t / 'validation.md'),
               'visibility_manifest': {'visible_files': [], 'writable_files': ['src/impl.py']},
               'prompt': 'implement', 'timeout_s': 20, 'limits_registry': registry}
    result = r.run_attempt(request, name, registry['providers'][name], 1, 'codex')
    assert target.exists(), f'{name}: provider child did not run ({result.get("error_class")})'
    return json.loads(target.read_text())

codex_env = spawn('codexish')
assert codex_env.get('FAKE_KEY') == 'fake-secret'
for absent in ('ZAI_API_KEY', 'OPENROUTER_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENROUTER_MANAGEMENT_KEY'):
    assert absent not in codex_env, f'codex-cli child leaked {absent}'

zai_env = spawn('zai')
assert zai_env.get('ZAI_API_KEY') == 'zai-secret'
assert zai_env.get('OPENAI_API_KEY') == 'zai-secret', 'aider adapter must map its OWN key, not a stale one'
for absent in ('OPENROUTER_API_KEY', 'FAKE_KEY', 'ANTHROPIC_API_KEY', 'OPENROUTER_MANAGEMENT_KEY'):
    assert absent not in zai_env, f'aider child leaked {absent}'

subprocess.run(['git', '-C', str(repo), 'reset', '-q', '--hard', base], check=True)
or_env = spawn('openrouter')
assert or_env.get('OPENROUTER_API_KEY') == 'or-secret'
for absent in ('ZAI_API_KEY', 'FAKE_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENROUTER_MANAGEMENT_KEY'):
    assert absent not in or_env, f'openrouter child leaked {absent}'
subprocess.run(['git', '-C', str(repo), 'reset', '-q', '--hard', base], check=True)
print('CE1 OK')
PY

# ---- VM: the four audit neuter-probes are no longer invisible ------------
# (v0.40 retro §2: deleting these branches left the suite at 191/0)
# VM1: a provider that mutates the generated limits context is parked by the
# PRE-done-gate visibility re-check.
python3 - "$T" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1])
(t/'fake-mutator').write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
    "runtime = Path('.parallax/demo/runtime/limits.context.md')\n"
    "runtime.write_text('tampered\\n')\n"
    "Path('src/impl.py').write_text('implemented\\n')\nprint('{\"event\":\"done\"}')\n")
(t/'fake-mutator').chmod(0o755)
PY
cat > "$T/vm1.toml" <<EOF
host_provider = "codex"
provider_state_db = "$T/vm-state.sqlite"
[providers.mutator]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-mutator"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[roles.blind_coder]
chain = ["mutator"]
required_capabilities = ["read", "write"]
EOF
git -C "$REPO" reset -q --hard "$BASE"
mkreq "$T/vm1-req.json" "d['chain'] = ['mutator']"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/vm1-req.json" --registry "$T/vm1.toml" --host codex > "$T/vm1.out"; then
  fail 'VM1: a provider that tampered with the generated control artifact exited 0'
fi
grep -q '"error_class": "visibility-manifest-violation"' "$T/vm1.out" || { cat "$T/vm1.out"; fail 'VM1: runtime-artifact tampering was not parked visibility-manifest-violation'; }

# VM2: a NON-disposable dirty failed attempt parks partial-edit-not-reconciled
# instead of silently rolling into the next provider.
python3 - "$T" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1])
(t/'fake-dirty-fail').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
    "Path('src/unexpected.py').write_text('dirty\\n')\nprint('provider crashed', flush=True)\nraise SystemExit(3)\n")
(t/'fake-dirty-fail').chmod(0o755)
PY
cat > "$T/vm2.toml" <<EOF
host_provider = "codex"
provider_state_db = "$T/vm-state.sqlite"
[providers.dirty]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-dirty-fail"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[providers.fake]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[roles.blind_coder]
chain = ["dirty", "fake"]
required_capabilities = ["read", "write"]
EOF
git -C "$REPO" reset -q --hard "$BASE"
mkreq "$T/vm2-req.json" "d['chain'] = ['dirty', 'fake']; d['disposable_worktree'] = False; d['attempt_log'] = t + '/vm2-attempts.jsonl'"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/vm2-req.json" --registry "$T/vm2.toml" --host codex > "$T/vm2.out"; then
  fail 'VM2: non-disposable dirty failed attempt exited 0'
fi
grep -q '"error_class": "partial-edit-not-reconciled"' "$T/vm2.out" || { cat "$T/vm2.out"; fail 'VM2: dirty non-disposable attempt was not parked'; }
grep -q '"provider": "fake"' "$T/vm2-attempts.jsonl" && fail 'VM2: fallback ran over an unreconciled dirty worktree'
git -C "$REPO" reset -q --hard "$BASE"; git -C "$REPO" clean -qfd

# VM3: the POST-done-gate visibility re-check catches a done-gate that dirties
# the worktree outside the writable manifest.
python3 - "$T" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1])
(t/'dirty-gate').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('src/gate_artifact.py').write_text('generated\\n')\n")
(t/'dirty-gate').chmod(0o755)
PY
git -C "$REPO" reset -q --hard "$BASE"
mkreq "$T/vm3-req.json" "d['chain'] = ['fake']; d['done_gate'] = ['$T/dirty-gate']"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/vm3-req.json" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/vm3.out"; then
  fail 'VM3: a done-gate that dirtied the worktree exited 0'
fi
grep -q '"error_class": "visibility-manifest-violation"' "$T/vm3.out" || { cat "$T/vm3.out"; fail 'VM3: post-done-gate dirt was not parked visibility-manifest-violation'; }
git -C "$REPO" reset -q --hard "$BASE"; git -C "$REPO" clean -qfd

# ---- RP2/RP3: reviewer smoke surface exists; blocked never exits 0 -------
cat > "$T/rp.toml" <<EOF
provider_state_db = "$T/state.sqlite"
[providers.zai_reviewer]
kind = "reviewer"
transport = "review-api"
model = "glm-5.2"
base_url = "https://api.z.ai/api/paas/v4/chat/completions"
key_env = "ZAI_API_KEY"
review_thinking = "disabled"
review_thinking_supported = true
capabilities = ["read", "structured_output"]
EOF
if python3 "$PLUGIN/scripts/provider-runtime.py" live-smoke --provider zai_reviewer --model glm-5.2 \
     --max-output-tokens 64 --max-cost-usd 0.05 --repo "$REPO" --config "$T/rp.toml" --reviewer > "$T/rp2.out"; then
  fail 'RP3: blocked live-smoke exited 0'
fi
grep -q 'unsupported_smoke_transport' "$T/rp2.out" && fail 'RP2: reviewer transport is still unsupported in live-smoke'
grep -q '"error_class": "confirm_spend_required"' "$T/rp2.out" || { cat "$T/rp2.out"; fail 'RP: expected confirm_spend gate first'; }
# with spend confirmed but no key authorization, the production key is refused —
# still blocked, still non-zero, and NO network call is possible (no cap bypass).
if python3 "$PLUGIN/scripts/provider-runtime.py" live-smoke --provider zai_reviewer --model glm-5.2 \
     --max-output-tokens 64 --max-cost-usd 0.05 --repo "$REPO" --config "$T/rp.toml" --reviewer --confirm-spend > "$T/rp2b.out"; then
  fail 'RP3: production-key-refused smoke exited 0'
fi
grep -q '"error_class": "production_key_not_authorized"' "$T/rp2b.out" || { cat "$T/rp2b.out"; fail 'RP: production key was not refused by default'; }
# the worker-transport smoke path still fails closed and non-zero
if python3 "$PLUGIN/scripts/provider-runtime.py" live-smoke --provider zai_reviewer --model glm-5.2 \
     --max-output-tokens 4 --max-cost-usd 0.01 --repo "$REPO" --config "$T/rp.toml" > "$T/rp3.out"; then
  fail 'RP3: blocked non-reviewer smoke exited 0'
fi

echo 't_provider_containment OK'
