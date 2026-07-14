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
printf '*.env\n' > "$T/repo/.gitignore"
printf 'base\n' > "$T/repo/src/base.py"
cat > "$T/direct" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path
counter=Path(os.environ['DIRECT_COUNTER'])
counter.write_text(str(int(counter.read_text())+1 if counter.exists() else 1))
if os.environ.get('ZAI_API_KEY') == 'old-key':
    print('business code: 1113 insufficient balance')
    raise SystemExit(9)
Path('src/impl.py').write_text('direct\n')
print('{"event":"direct-ok"}')
PY
cat > "$T/openrouter" <<'PY'
#!/usr/bin/env python3
import sys
from pathlib import Path
if "--version" in sys.argv:
    print("Aider v0.86.1")
    raise SystemExit(0)
Path('src/impl.py').write_text('openrouter\n')
print('{"event":"openrouter-ok"}')
PY
cat > "$T/budget" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({'status':'known','remaining':12.0,'currency':'USD','exact_balance':True}))
PY
chmod +x "$T/direct" "$T/openrouter" "$T/budget"
export DIRECT_COUNTER="$T/direct-count"
cat > "$T/repo/.parallax/providers.toml" <<EOF
provider_state_db = "$T/provider-state.sqlite"
probe_policy = "explicit"
[limits]
warning_threshold_pct = 80
handoff_threshold_pct = 90
unknown_policy = "continue-with-warning"
stale_ttl_s = 120
max_sleep_s = 3600
reset_jitter_s = 0
[providers.zai]
kind = "worker"
transport = "aider-api"
command = "$T/direct"
base_url = "https://api.z.ai/api/paas/v4"
key_env = "ZAI_API_KEY"
credential_class = "zai-api"
model = "glm-5.2"
operator_budget_usd = 7.0
operator_budget_scope = "estimate-only"
fallback_providers = ["openrouter_glm52"]
[providers.openrouter_glm52]
kind = "worker"
transport = "openrouter-api"
command = "$T/openrouter"
base_url = "https://openrouter.ai/api/v1"
key_env = "OPENROUTER_API_KEY"
model = "z-ai/glm-5.2"
budget_source_class = "official-api"
budget_key_endpoint = "https://openrouter.ai/api/v1/key"
budget_exact = true
budget_command = "$T/budget"
probe_read_only = true
balance_scope = "openrouter-key"
[providers.openrouter_glm52.routing]
only = ["z-ai"]
allow_fallbacks = false
data_retention_policy = "test-policy"
[roles.blind_coder]
chain = ["zai"]
EOF
cat > "$T/repo/.parallax/.env" <<'EOF'
ZAI_API_KEY=old-key
OPENROUTER_API_KEY=openrouter-key
EOF
git -C "$T/repo" add . && git -C "$T/repo" commit -qm base
git -C "$T/repo" switch -qc feature/state
BASE=$(git -C "$T/repo" rev-parse HEAD)
printf 'spec\n' > "$T/spec.md"; printf 'validation\n' > "$T/validation.md"
python3 - "$T/request.json" "$T/repo" "$BASE" "$T" <<'PY'
import json,sys
out,repo,base,t=sys.argv[1:]
json.dump({'repo':repo,'role':'blind-coder','slice_id':'S1','slug':'state','run_id':'state-run','side':'code','worktree':repo,'expected_branch':'feature/state','clean_base':base,'disposable_worktree':True,'spec_path':t+'/spec.md','validation_path':t+'/validation.md','visibility_manifest':{'visible_files':['src/base.py'],'writable_files':['src/impl.py']},'prompt':'Implement the frozen behavior.','timeout_s':20,'attempt_log':t+'/attempts.jsonl','attempt_artifacts':t+'/attempt-artifacts'},open(out,'w'))
PY
FIRST=$(python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/request.json" --registry "$T/repo/.parallax/providers.toml" --host codex)
echo "$FIRST" | grep -q '"provider": "openrouter_glm52"' || { echo "$FIRST"; fail 'exhausted direct z.ai did not route to OpenRouter'; }
[ "$(cat "$T/direct-count")" = 1 ] || fail 'direct z.ai did not run exactly once on initial exhaustion'
grep -q '^openrouter$' "$T/repo/src/impl.py" || fail 'OpenRouter fallback did not own the logical model result'
git -C "$T/repo" reset -q --hard "$BASE"
SECOND=$(python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/request.json" --registry "$T/repo/.parallax/providers.toml" --host codex)
echo "$SECOND" | grep -q '"provider": "openrouter_glm52"' || fail 'persistent exhausted state did not skip direct z.ai'
[ "$(cat "$T/direct-count")" = 1 ] || fail 'persistent exhausted state retried direct z.ai'
python3 - "$T/provider-state.sqlite" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1]); row=db.execute("select last_status,last_error_class,operator_budget_remaining,key_fingerprint from provider_state where provider='zai'").fetchone()
assert row[0]=='exhausted' and row[1]=='insufficient_balance' and row[2]==7.0 and row[3] not in {'old-key',''}
PY
printf 'ZAI_API_KEY=new-key\nOPENROUTER_API_KEY=openrouter-key\n' > "$T/repo/.parallax/.env"
git -C "$T/repo" reset -q --hard "$BASE"
THIRD=$(python3 "$PLUGIN/scripts/provider-runtime.py" dispatch --request "$T/request.json" --registry "$T/repo/.parallax/providers.toml" --host codex)
echo "$THIRD" | grep -q '"provider": "zai"' || { echo "$THIRD"; fail 'new z.ai fingerprint remained blocked by old exhausted state'; }
[ "$(cat "$T/direct-count")" = 2 ] || fail 'new fingerprint did not retry direct z.ai'
python3 "$PLUGIN/scripts/provider-runtime.py" limits z.ai --repo "$T/repo" --config "$T/repo/.parallax/providers.toml" --json > "$T/limits.json"
python3 - "$T/limits.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['budget']['remaining'] is None and d['budget']['exact'] is False; assert d['operator_estimate']['remaining']==7.0 and d['operator_estimate']['label']=='operator-estimate'
PY
echo 't_provider_state OK'
