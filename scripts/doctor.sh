#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"
VENV_PY="${HOME_DIR}/.local/share/memory-fabric/venv/bin/python"
WRAPPER="${HOME_DIR}/.local/share/memory-fabric/bin/memory-hub"
HOOK="${HOME_DIR}/.claude/hooks/memory_fabric/user_prompt_submit.py"

echo "==> Check runtime wrapper"
"${WRAPPER}" --help >/dev/null
echo "OK: memory-hub wrapper"

echo "==> Check assemble punctuation (FTS sanitize regression)"
"${WRAPPER}" assemble "hello, do you see my project memory?" --max-tokens 1200 --json | python3 -m json.tool >/dev/null
echo "OK: assemble punctuation"

echo "==> Hook mock: prompt field"
cat <<'JSON' | "${VENV_PY}" "${HOOK}" | python3 -m json.tool >/dev/null
{"hookEventName":"UserPromptSubmit","session_id":"doctor-prompt","cwd":"${ROOT}","prompt":"hello, do you see my project memory?"}
JSON
echo "OK: UserPromptSubmit(prompt)"

echo "==> Hook mock: userPrompt field"
cat <<'JSON' | "${VENV_PY}" "${HOOK}" | python3 -m json.tool >/dev/null
{"hookEventName":"UserPromptSubmit","session_id":"doctor-userPrompt","cwd":"${ROOT}","userPrompt":"hello, do you see my project memory?"}
JSON
echo "OK: UserPromptSubmit(userPrompt)"

echo "==> Hook mock: project override detection"
# Test from outside project directory - should detect p009_memory_fabric_global
INPUT='{"hookEventName":"UserPromptSubmit","session_id":"doctor-override","cwd":"/tmp","prompt":"status of p009_memory_fabric_global"}'
OUTPUT=$(echo "$INPUT" | "${VENV_PY}" "${HOOK}")
# Use Python to extract and check additionalContext
echo "$OUTPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    if 'PROJECT_OVERRIDE: p009_memory_fabric_global' in ctx:
        sys.exit(0)
    else:
        print('FAIL: marker not found')
        sys.exit(1)
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" && echo "OK: Project override detected from /tmp directory"

echo "==> Hook mock: no override (existing behavior)"
# Test without project mention - should NOT include override marker
INPUT2='{"hookEventName":"UserPromptSubmit","session_id":"doctor-no-override","cwd":"/tmp","prompt":"hello world"}'
OUTPUT2=$(echo "$INPUT2" | "${VENV_PY}" "${HOOK}")
echo "$OUTPUT2" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    if 'PROJECT_OVERRIDE' in ctx:
        print('FAIL: unexpected override marker found')
        sys.exit(1)
    else:
        sys.exit(0)
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" && echo "OK: No override marker when prompt has no project mention"

echo "✅ Doctor PASS"
