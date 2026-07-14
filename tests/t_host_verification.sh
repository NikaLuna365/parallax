#!/usr/bin/env bash
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then exit 0; fi
exit 9
EOF
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then exit 0; fi
if [ "${1:-}" = "doctor" ]; then exit 0; fi
exit 9
EOF
chmod +x "$T/bin/claude" "$T/bin/codex"
PATH="$T/bin:$PATH" python3 "$PLUGIN/scripts/host-verification.py" --skip-doctor > "$T/host.json"
python3 - "$T/host.json" "$PLUGIN" <<'PY'
import json, sys
from pathlib import Path
doc=json.load(open(sys.argv[1]))
assert doc['hosts']['claude-code']['cli_available'] is True
assert doc['hosts']['codex']['version_check'] == 'ok'
assert doc['hosts']['codex']['doctor']['role'] == 'diagnostic-only'
assert doc['hosts']['claude-code']['quota_evidence'] == 'unknown'
assert doc['hosts']['codex']['quota_evidence'] == 'unknown'
assert doc['host_smoke'] == 'host_smoke_not_safe'
sys.path.insert(0, str(Path(sys.argv[2])/'scripts'))
from provider_runtime import _find_signal
assert _find_signal({'rate_limits': {'used_percentage': 81, 'resets_at': '2030-01-01T00:00:00Z'}})['used_percentage'] == 81
assert _find_signal({'usage': {'used_percentage': 12}, 'status': {'reset_at': '2030-01-01T00:00:00Z'}})['used_percentage'] == 12
assert _find_signal({'authenticated': 'yes'})['used_percentage'] is None
PY
echo 't_host_verification OK'
