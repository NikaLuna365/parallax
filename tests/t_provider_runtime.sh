#!/usr/bin/env bash
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
fail(){ echo "FAIL: $*" >&2; exit 1; }
python3 - "$T" <<'PY'
from pathlib import Path
import sys
t=Path(sys.argv[1])
(t/'fake-success').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('src/impl.py').write_text('implemented\\n')\nprint('{\\\"event\\\":\\\"done\\\"}')\n")
(t/'fake-limit').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('src/partial.py').write_text('discard me\\n')\nprint('quota exhausted', flush=True)\nraise SystemExit(9)\n")
for p in (t/'fake-success',t/'fake-limit'): p.chmod(0o755)
PY
REPO="$T/repo"; mkdir -p "$REPO/.parallax" "$REPO/src"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.invalid; git -C "$REPO" config user.name test
printf '*.env\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/src/base.py"; git -C "$REPO" add .; git -C "$REPO" commit -qm base
cat > "$REPO/.parallax/providers.toml" <<EOF
host_provider = "codex"
fallback_policy = "ordered-clean-base"
[providers.fake]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
key_env = "FAKE_KEY"
capabilities = ["read", "write", "shell"]
[providers.limited]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-limit"
model = "fake-model"
capabilities = ["read", "write", "shell"]
[roles.blind_coder]
chain = ["fake"]
required_capabilities = ["read", "write"]
automatic_fallback = true
EOF
git -C "$REPO" add .parallax/providers.toml; git -C "$REPO" commit -qm providers
printf 'FAKE_KEY=SUPERSECRET_VALUE\n' > "$REPO/.parallax/.env"
cat > "$T/bad.toml" <<EOF
[providers.bad]
kind = "worker"
transport = "aider-api"
command = "aider"
api_key = "SUPERSECRET_VALUE"
EOF
if python3 "$PLUGIN/scripts/provider-runtime.py" validate-registry --repo "$REPO" --config "$T/bad.toml" > "$T/bad.out" 2>&1; then fail 'secret-bearing tracked-style registry accepted'; fi
grep -q 'SUPERSECRET_VALUE' "$T/bad.out" && fail 'secret value echoed in registry error'
PREFLIGHT=$(python3 "$PLUGIN/scripts/provider-runtime.py" preflight --repo "$REPO")
printf '%s' "$PREFLIGHT" | grep -q '"configured": true' || fail 'project env presence not detected'
printf '%s' "$PREFLIGHT" | grep -q 'project-local' || fail 'env source not reported'
printf '%s' "$PREFLIGHT" | grep -q 'SUPERSECRET_VALUE' && fail 'secret leaked in preflight'
printf '%s' "$PREFLIGHT" | grep -q '"status": "unknown"' || fail 'unsupported budget was not unknown'
printf '%s' "$PREFLIGHT" | grep -q '"remaining": null' || fail 'unknown budget invented remaining balance'
python3 - "$PLUGIN" "$T" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
budget_script = Path(sys.argv[2])/'budget.py'
budget_script.write_text("import json; print(json.dumps({'status':'known','remaining':99.0,'currency':'USD','exact_balance':True}))")
fake = {"transport":"aider-api", "command":"true", "model":"m", "budget_source_class":"official-dashboard",
        "budget_command": f"{sys.executable} {budget_script}", "probe_read_only":True}
dashboard = r._budget_report(Path('.'), 'dashboard', fake, {"configured":True,"command_available":True,"authenticated":"unknown"})
assert dashboard['budget']['status'] == 'unknown' and dashboard['budget']['remaining'] is None
exact = {**fake, 'budget_source_class':'official-api'}
official = r._budget_report(Path('.'), 'official', exact, {"configured":True,"command_available":True,"authenticated":"unknown"},
                            registry={"probe_policy":"explicit"}, probe_auth=True)
assert official['budget']['status'] == 'known' and official['budget']['remaining'] == 99.0
PY

PLAN="$T/plan.json"
python3 "$PLUGIN/scripts/provider-runtime.py" plan --repo "$REPO" --output "$PLAN" >/dev/null
python3 - "$PLAN" "$T/selection.json" <<'PY'
import json,sys
plan=json.load(open(sys.argv[1])); plan['roles']['blind_coder']['chain']=['fake']; plan['host_provider']='codex'
json.dump({'confirmed':True,'host_provider':'codex','fallback_policy':'ordered-clean-base','roles':{'blind_coder':plan['roles']['blind_coder']}},open(sys.argv[2],'w'))
PY
CONTRACT="$T/provider-contract.json"
python3 "$PLUGIN/scripts/provider-runtime.py" freeze --plan "$PLAN" --selection "$T/selection.json" --output "$CONTRACT" >/dev/null
grep -q '"schema_version": "parallax-provider-contract-v1"' "$CONTRACT" || fail 'frozen provider contract missing'
git -C "$REPO" switch -qc feature/demo-S1-code
BASE=$(git -C "$REPO" rev-parse HEAD)
REQ="$T/request.json"
printf 'frozen spec\n' > "$T/spec.md"
printf 'validation\n' > "$T/validation.md"
python3 - "$REQ" "$REPO" "$BASE" "$T" <<'PY'
import json,sys
out,repo,base,t=sys.argv[1:]
json.dump({'repo':repo,'role':'blind-coder','slice_id':'S1','slug':'demo','run_id':'run-1','side':'code','worktree':repo,'expected_branch':'feature/demo-S1-code','clean_base':base,'disposable_worktree':True,'chain':['fake'],'spec_path':t+'/spec.md','validation_path':t+'/validation.md','visibility_manifest':{'visible_files':['src/base.py'],'writable_files':['src/impl.py']},'prompt':'Read the frozen spec and implement the assigned behavior.','timeout_s':20,'attempt_log':t+'/attempts.jsonl','attempt_artifacts':t+'/attempt-artifacts','evidence_dir':t+'/evidence'},open(out,'w'))
PY
python3 - "$PLUGIN" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
adapted = r._aider_child_env({'transport':'aider-api','key_env':'ZAI_API_KEY'}, {'ZAI_API_KEY':'zai-test-secret','OPENAI_API_KEY':'stale-key'})
assert adapted['OPENAI_API_KEY'] == 'zai-test-secret'
assert adapted['ZAI_API_KEY'] == 'zai-test-secret'
unchanged = r._aider_child_env({'transport':'openrouter-api','key_env':'OPENROUTER_API_KEY'}, {'OPENROUTER_API_KEY':'or-test-secret'})
assert 'OPENAI_API_KEY' not in unchanged
cmd=r._provider_command({'transport':'aider-api','command':sys.executable,'model':'m','base_url':'https://example.invalid','key_env':'FAKE_KEY'}, {'worktree':'.','visibility_manifest':{'visible_files':['spec.md'],'writable_files':['src/impl.py']}}, Path('/tmp/prompt'))
assert cmd.count('--read') == 1 and 'spec.md' in cmd and cmd.count('--file') == 1 and 'src/impl.py' in cmd
assert '--no-auto-commits' in cmd
assert '--yes-always' in cmd and '--yes' not in cmd
direct=r._provider_command({'transport':'aider-api','command':sys.executable,'model':'glm-5.2','base_url':'https://api.z.ai/api/paas/v4','key_env':'ZAI_API_KEY'}, {'worktree':'.','visibility_manifest':{'visible_files':['spec.md'],'writable_files':['src/impl.py']}}, Path('/tmp/prompt'))
assert direct[direct.index('--model')+1] == 'glm-5.2'
assert direct[direct.index('--openai-api-base')+1] == 'https://api.z.ai/api/paas/v4'
assert '--yes-always' in direct and '--yes' not in direct
openrouter=r._provider_command({'transport':'openrouter-api','command':sys.executable,'model':'z-ai/glm-5.2','key_env':'OPENROUTER_API_KEY'}, {'worktree':'.','visibility_manifest':{'visible_files':['spec.md'],'writable_files':['src/impl.py']}}, Path('/tmp/prompt'))
assert openrouter[openrouter.index('--model')+1] == 'openrouter/z-ai/glm-5.2'
assert '--openai-api-base' not in openrouter
try: r._provider_command({'transport':'openrouter-api','command':'definitely-missing-aider','model':'z-ai/glm-5.2','key_env':'OPENROUTER_API_KEY'}, {'worktree':'.','visibility_manifest':{'visible_files':[],'writable_files':['x']}}, Path('/tmp/prompt'))
except ValueError as exc: assert str(exc) == 'aider_missing'
else: raise AssertionError('missing Aider was not fail-closed')
PY
python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$REQ" --registry "$REPO/.parallax/providers.toml" --host codex > "$T/dispatch.json"
grep -q '"status": "committed"' "$T/dispatch.json" || { cat "$T/dispatch.json"; fail 'fake Codex worker did not commit'; }
grep -q 'provider_attempt' "$T/evidence/events.jsonl" || fail 'provider identity event was not written'
git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -qx 'src/impl.py' || fail 'worker commit contained unexpected files'
python3 - "$T/dispatch.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
observation=result.get('limit_observation') or {}
assert result['limit_action'] == 'continue'
assert observation['live_status'] == 'unknown'
assert observation['predictive'] is False
PY

sed "s#command = \"$T/fake-success\"#command = \"$T/fake-limit\"#" "$REPO/.parallax/providers.toml" > "$T/fallback.toml"
cat >> "$T/fallback.toml" <<EOF
[providers.recovery]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
capabilities = ["read", "write", "shell"]
EOF
sed -i 's/chain = \["fake"\]/chain = ["limited", "recovery"]/' "$T/fallback.toml"
git -C "$REPO" reset -q --hard "$BASE"
python3 - "$REQ" "$BASE" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['chain']=['limited','recovery']; p['clean_base']=sys.argv[2]; json.dump(p,open(sys.argv[1],'w'))
PY
python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$REQ" --registry "$T/fallback.toml" --host codex > "$T/fallback.json"
grep -q '"status": "committed"' "$T/fallback.json" || { cat "$T/fallback.json"; fail 'fallback did not recover'; }
git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -qx 'src/impl.py' || fail 'partial failed edit mixed into fallback'
[ ! -e "$REPO/src/partial.py" ] || fail 'partial failed edit survived reset'
grep -q '"provider": "limited"' "$T/attempts.jsonl" || fail 'limit attempt not recorded'
grep -q '"provider": "recovery"' "$T/attempts.jsonl" || fail 'fallback attempt not recorded'

# Safe-boundary guard: a near/exhausted signal hands off before invoking the
# provider. The fallback owns the commit; the limited provider must not run.
python3 - "$T" <<'PY'
import json,sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
t=Path(sys.argv[1])
(t/'fake-near').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('near-provider-ran').write_text('unexpected\\n')\nprint('{\\\"event\\\":\\\"near-ran\\\"}')\n")
(t/'fake-near').chmod(0o755)
signal={'used_percentage':95,'resets_at':(datetime.now(timezone.utc)+timedelta(seconds=600)).isoformat().replace('+00:00','Z'),'source_class':'official-cli'}
(t/'near-signal.json').write_text(json.dumps(signal))
PY
cat > "$T/guard.toml" <<EOF
host_provider = "codex"
fallback_policy = "ordered-clean-base"
[providers.near]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-near"
model = "fake-model"
live_signal_path = "$T/near-signal.json"
live_signal_source_class = "official-cli"
max_sleep_s = 60
[providers.fake]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-success"
model = "fake-model"
[roles.blind_coder]
chain = ["near", "fake"]
required_capabilities = ["read", "write"]
automatic_fallback = true
EOF
git -C "$REPO" reset -q --hard "$BASE"
python3 - "$REQ" "$BASE" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['chain']=['near','fake']; p['clean_base']=sys.argv[2]; json.dump(p,open(sys.argv[1],'w'))
PY
python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$REQ" --registry "$T/guard.toml" --host codex > "$T/guard.json"
grep -q '"status": "committed"' "$T/guard.json" || { cat "$T/guard.json"; fail 'safe-boundary handoff did not reach fallback'; }
[ ! -e "$REPO/near-provider-ran" ] || fail 'near provider ran after handoff boundary'
python3 - "$T/guard.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); first=r['fallback_attempts'][0]
assert first['status'] == 'limit'
assert first['limit_action'] == 'handoff'
assert first['limit_observation']['boundary'] == 'before_request'
PY

# With no fallback, the same signal parks with an honest bounded reset action;
# the CLI reports it and does not sleep unless --sleep is explicitly supplied.
python3 - "$REQ" "$BASE" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['chain']=['near']; p['clean_base']=sys.argv[2]; json.dump(p,open(sys.argv[1],'w'))
PY
git -C "$REPO" reset -q --hard "$BASE"
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$REQ" --registry "$T/guard.toml" --host codex > "$T/sleep.json"; then fail 'sleep_until_reset was reported as success'; fi
python3 - "$T/sleep.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['status'] == 'parked'
assert r['error_class'] == 'sleep_until_reset'
assert r['limit_action'] == 'sleep_until_reset'
assert r['limit_observation']['reset_seconds'] > 0
assert 0 < r['limit_observation']['sleep_seconds'] <= 3600 + 300
PY

python3 - "$REQ" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['visibility_manifest']['writable_files']=[]; json.dump(p,open(sys.argv[1],'w'))
PY
if python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$REQ" --registry "$REPO/.parallax/providers.toml" --host codex >/dev/null 2>&1; then fail 'empty writable manifest was accepted'; fi

# The Codex-host seam uses the same request and emits a host artifact.
python3 - "$REQ" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['visibility_manifest']['writable_files']=['src/impl.py']; p['chain']=['fake']; json.dump(p,open(sys.argv[1],'w'))
PY
git -C "$REPO" reset -q --hard "$BASE"
python3 "$PLUGIN/scripts/codex-host.py" --request "$REQ" --registry "$REPO/.parallax/providers.toml" --host codex --artifact-dir "$T/host" > "$T/host-result.json"
grep -q '"status": "committed"' "$T/host-result.json" || fail 'Codex host did not reach shared worker gates'
[ -s "$T/host/host-run.json" ] || fail 'Codex host did not write host artifact'
echo 't_provider_runtime OK'
