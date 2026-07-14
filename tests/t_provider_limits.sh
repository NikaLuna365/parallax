#!/usr/bin/env bash
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
fail(){ echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$T/repo/.parallax" "$T/repo/src"
git init -q "$T/repo"
git -C "$T/repo" config user.email test@example.invalid
git -C "$T/repo" config user.name test
printf 'base\n' > "$T/repo/src/base.py"
cat > "$T/fake-worker" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
Path('worker-ran').write_text('unexpected\n')
print('{"event":"worker"}')
PY
cat > "$T/fake-probe" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
Path('probe-ran').write_text('explicit\n')
print('{"authenticated":"yes"}')
PY
cat > "$T/fake-budget" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
Path('budget-ran').write_text('unexpected on passive path\n')
print('{"status":"known","remaining":9.0,"currency":"USD","exact_balance":true}')
PY
chmod +x "$T/fake-worker" "$T/fake-probe" "$T/fake-budget"
cat > "$T/repo/.parallax/providers.toml" <<EOF
probe_policy = "explicit"
provider_state_db = "$T/state.sqlite"
[limits]
warning_threshold_pct = 80
handoff_threshold_pct = 90
unknown_policy = "continue-with-warning"
stale_ttl_s = 120
max_sleep_s = 3600
reset_jitter_s = 0
[providers.zai]
kind = "worker"
transport = "codex-cli"
command = "$T/fake-worker"
model = "glm-5.1"
limits_source_class = "official-dashboard"
limits_limitations = ["direct z.ai balance is not proven"]
probe_command = "$T/fake-probe"
probe_read_only = true
budget_command = "$T/fake-budget"
[providers.openrouter]
kind = "worker"
transport = "openrouter-api"
command = "$T/fake-worker"
base_url = "https://openrouter.ai/api/v1"
key_env = "OPENROUTER_API_KEY"
model = "z-ai/glm-5.1"
budget_source_class = "official-api"
budget_key_endpoint = "https://openrouter.ai/api/v1/key"
credits_endpoint = "https://openrouter.ai/api/v1/credits"
models_endpoint = "https://openrouter.ai/api/v1/models"
budget_exact = true
balance_scope = "openrouter-key"
[providers.openrouter.routing]
only = ["z-ai"]
allow_fallbacks = false
data_retention_policy = "test-policy"
EOF
git -C "$T/repo" add . && git -C "$T/repo" commit -qm base
JSON=$(python3 "$PLUGIN/scripts/provider-runtime.py" limits z.ai --repo "$T/repo" --config "$T/repo/.parallax/providers.toml" --json)
python3 - "$PLUGIN" "$JSON" <<'PY'
import json,sys
from pathlib import Path
import jsonschema
schema=json.loads((Path(sys.argv[1])/'assets/provider-limits.schema.json').read_text())
doc=json.loads(sys.argv[2]); jsonschema.validate(doc,schema)
assert doc['provider']=='zai' and doc['budget']['remaining'] is None
assert doc['budget']['exact'] is False and doc['source_class']=='official-dashboard'
assert doc['action']=='continue'
PY
[ ! -e "$T/repo/probe-ran" ] || fail 'ordinary limits ran arbitrary probe_command'
[ ! -e "$T/repo/worker-ran" ] || fail 'limits launched a worker/model command'
[ ! -e "$T/repo/budget-ran" ] || fail 'ordinary limits ran arbitrary budget_command'
ALIAS=$(python3 "$PLUGIN/scripts/provider-runtime.py" limit z.ai --repo "$T/repo" --config "$T/repo/.parallax/providers.toml" --json)
python3 - "$JSON" "$ALIAS" <<'PY'
import json,sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); assert a['provider']==b['provider']=='zai'
PY
python3 "$PLUGIN/scripts/provider-runtime.py" limits z.ai --repo "$T/repo" --config "$T/repo/.parallax/providers.toml" --probe-auth --json >/dev/null
[ -e "$T/repo/probe-ran" ] || fail 'explicit read-only probe did not run'
[ -e "$T/repo/budget-ran" ] || fail 'explicit read-only budget command did not run'
cat > "$T/signal.json" <<'EOF'
{"used_percentage":85,"source_class":"official-dashboard"}
EOF
python3 - "$T/repo/.parallax/providers.toml" "$T/signal.json" <<'PY'
from pathlib import Path
import os,sys
path=Path(sys.argv[1]); text=path.read_text(); path.write_text(text.replace('limits_source_class = "official-dashboard"','limits_source_class = "official-dashboard"\nlive_signal_path = "'+sys.argv[2]+'"'))
PY
WARN=$(python3 "$PLUGIN/scripts/provider-runtime.py" limits z.ai --repo "$T/repo" --config "$T/repo/.parallax/providers.toml" --json)
python3 - "$WARN" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d['live_signal']=='near' and d['action']=='continue'; assert any('warning threshold' in x for x in d['limitations'])
PY
python3 - "$PLUGIN" <<'PY'
import os,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
os.environ['OPENROUTER_API_KEY']='test-key'
class Resp:
    def __enter__(self): return self
    def __exit__(self,*args): return False
    def read(self): return b'{"limit_remaining":10,"limit":100,"limit_reset":2000000000}'
old=r.urllib.request.urlopen; r.urllib.request.urlopen=lambda *a,**k: Resp()
try:
    p={'transport':'openrouter-api','key_env':'OPENROUTER_API_KEY','budget_key_endpoint':'https://example.invalid/key','budget_source_class':'official-api','budget_exact':True}
    got=r._budget_report(Path('.'),'openrouter',p,{'configured':True,'command_available':True,'authenticated':'unknown'},probe_budget=True)
    assert got['budget']['status']=='known' and got['budget']['remaining']==10 and got['budget']['reset_at'].endswith('Z')
finally: r.urllib.request.urlopen=old
PY
python3 - "$PLUGIN" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
fixture=json.loads((Path(sys.argv[1])/'tests/fixtures/openrouter_models_glm52.json').read_text())
class Resp:
    def __enter__(self): return self
    def __exit__(self,*args): return False
    def read(self): return json.dumps(fixture).encode()
old=r.urllib.request.urlopen; r.urllib.request.urlopen=lambda *a,**k: Resp()
try:
    provider={'transport':'openrouter-api','key_env':'OPENROUTER_API_KEY','models_endpoint':'https://example.invalid/models','model':'z-ai/glm-5.2'}
    got=r._openrouter_catalog(Path('.'), provider)
    assert got['status']=='available' and got['requested_model']=='z-ai/glm-5.2'
    assert got['models'][0]['pricing']['prompt']=='0.0000004'
    assert 'response_format' in got['models'][0]['capabilities']
    assert 'raw_marker' not in json.dumps(got)
    missing=r._openrouter_catalog(Path('.'), {**provider,'model':'z-ai/not-in-fixture'})
    assert missing['status']=='model_unavailable'
finally: r.urllib.request.urlopen=old
PY
python3 - "$PLUGIN" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
try: r._provider_command({'transport':'openrouter-api','command':'aider','key_env':'ZAI_API_KEY'}, {'worktree':'.','visibility_manifest':{'visible_files':[],'writable_files':['x']}}, Path('/tmp/p'))
except ValueError: pass
else: raise AssertionError('OpenRouter accepted ZAI_API_KEY')
PY
python3 - "$PLUGIN" <<'PY'
import os,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
bad={'providers':{'openrouter':{'kind':'worker','transport':'openrouter-api','command':'aider','base_url':'https://openrouter.ai/api/v1','key_env':'OPENROUTER_API_KEY','model':'z-ai/glm-5.2','budget_key_endpoint':'https://openrouter.ai/api/v1/key','management_key_env':'OPENROUTER_MANAGEMENT_KEY'}}}
try:
    r._validate_registry_doc(bad)
except ValueError as exc:
    assert 'credits_key_env' in str(exc)
else:
    raise AssertionError('legacy management_key_env was accepted')
os.environ['OPENROUTER_MANAGEMENT_KEY']='management-test-only'
env=r._child_env(Path('.'),'OPENROUTER_API_KEY')
assert 'OPENROUTER_MANAGEMENT_KEY' not in env
PY
python3 - "$PLUGIN" <<'PY'
import os,sys
from pathlib import Path
import urllib.error
sys.path.insert(0,str(Path(sys.argv[1])/'scripts'))
import provider_runtime as r
os.environ['ZAI_API_KEY']='test-zai-key'
provider={'kind':'worker','transport':'aider-api','command':sys.executable,'model':'glm-5.2','key_env':'ZAI_API_KEY',
          'auth_probe':'zai-models','auth_endpoint':'https://api.z.ai/api/paas/v4/models','auth_method':'GET'}
registry={'probe_policy':'explicit'}
calls=[]
class Resp:
    def __init__(self,code): self.code=code
    def __enter__(self): return self
    def __exit__(self,*args): return False
    def getcode(self): return self.code
def ok(*args,**kwargs): calls.append(1); return Resp(200)
old=r.urllib.request.urlopen
r.urllib.request.urlopen=ok
try:
    passive=r._provider_report(Path('.'),'zai',provider,registry,probe_auth=False)
    assert passive['probe_status']=='not-run-explicit-opt-in-required' and not calls
    live=r._provider_report(Path('.'),'zai',provider,registry,probe_auth=True)
    assert live['probe_status']=='http_200' and live['probe_error_class'] is None and live['probe_http_status']==200
    def unauthorized(*args,**kwargs): raise urllib.error.HTTPError(args[0].full_url,401,'unauthorized',None,None)
    r.urllib.request.urlopen=unauthorized
    failed=r._provider_report(Path('.'),'zai',provider,registry,probe_auth=True)
    assert failed['probe_status']=='http_401' and failed['probe_error_class']=='auth_failed' and failed['authenticated']=='no'
    def network(*args,**kwargs): raise urllib.error.URLError('offline')
    r.urllib.request.urlopen=network
    unavailable=r._provider_report(Path('.'),'zai',provider,registry,probe_all=True)
    assert unavailable['probe_status']=='network_failure' and unavailable['probe_error_class']=='network_failure'
finally:
    r.urllib.request.urlopen=old
PY
echo 't_provider_limits OK'
