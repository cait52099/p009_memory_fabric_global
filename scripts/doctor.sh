#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"
VENV_PY="${HOME_DIR}/.local/share/memory-fabric/venv/bin/python"
WRAPPER="${HOME_DIR}/.local/share/memory-fabric/bin/memory-hub"
HOOK="${HOME_DIR}/.claude/hooks/memory_fabric/user_prompt_submit.py"

# Helper functions for fail-fast
fail() {
    echo "FAIL: $1" >&2
    exit 1
}

ok() {
    echo "OK: $1"
}

echo "==> Check runtime wrapper"
"${WRAPPER}" --help >/dev/null || fail "memory-hub wrapper not accessible"
ok "memory-hub wrapper"

echo "==> Check assemble punctuation (FTS sanitize regression)"
"${WRAPPER}" assemble "hello, do you see my project memory?" --max-tokens 1200 --json | python3 -m json.tool >/dev/null || fail "assemble punctuation check"
ok "assemble punctuation"

echo "==> Hook mock: prompt field"
cat <<'JSON' | "${VENV_PY}" "${HOOK}" | python3 -m json.tool >/dev/null || fail "UserPromptSubmit prompt field"
{"hookEventName":"UserPromptSubmit","session_id":"doctor-prompt","cwd":"${ROOT}","prompt":"hello, do you see my project memory?"}
JSON
ok "UserPromptSubmit(prompt)"

echo "==> Hook mock: userPrompt field"
cat <<'JSON' | "${VENV_PY}" "${HOOK}" | python3 -m json.tool >/dev/null || fail "UserPromptSubmit userPrompt field"
{"hookEventName":"UserPromptSubmit","session_id":"doctor-userPrompt","cwd":"${ROOT}","userPrompt":"hello, do you see my project memory?"}
JSON
ok "UserPromptSubmit(userPrompt)"

echo "==> Hook mock: project override detection"
# Test from outside project directory - should detect p009_memory_fabric_global
INPUT='{"hookEventName":"UserPromptSubmit","session_id":"doctor-override","cwd":"/tmp","prompt":"status of p009_memory_fabric_global"}'
OUTPUT=$(echo "$INPUT" | "${VENV_PY}" "${HOOK}")
# Extract and check additionalContext - must contain override marker
CHECK_RESULT=$(echo "$OUTPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    if 'PROJECT_OVERRIDE: p009_memory_fabric_global' in ctx:
        print('PASS')
    else:
        print('FAIL: marker not found')
except Exception as e:
    print(f'FAIL: {e}')
" || echo "FAIL: python error")
[ "$CHECK_RESULT" = "PASS" ] || fail "project override detection"
ok "Project override detected from /tmp directory"

echo "==> Hook mock: no override (existing behavior)"
# Test without project mention - should NOT include override marker
INPUT2='{"hookEventName":"UserPromptSubmit","session_id":"doctor-no-override","cwd":"/tmp","prompt":"hello world"}'
OUTPUT2=$(echo "$INPUT2" | "${VENV_PY}" "${HOOK}")
CHECK_RESULT2=$(echo "$OUTPUT2" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    if 'PROJECT_OVERRIDE' in ctx:
        print('FAIL: unexpected override marker found')
    else:
        print('PASS')
except Exception as e:
    print(f'FAIL: {e}')
" || echo "FAIL: python error")
[ "$CHECK_RESULT2" = "PASS" ] || fail "$CHECK_RESULT2"
ok "No override marker when prompt has no project mention"

echo "==> Global Project Registry: write snapshot and verify retrieval"
# Step 1: Write a registry snapshot for p009_memory_fabric_global
REGISTRY_TOKEN="REGISTRY_E2E_TOKEN_$(date +%s)"
"${WRAPPER}" write "p009_memory_fabric_global | https://github.com/test/p009 | 2026-02-26T12:00:00Z | ${REGISTRY_TOKEN}" --type project_snapshot --source "global:project_registry" >/dev/null || fail "write registry snapshot"
echo "Wrote registry token: ${REGISTRY_TOKEN}"

# Step 2: Call hook with generic prompt asking about recent projects
INPUT_REG='{"hookEventName":"UserPromptSubmit","session_id":"doctor-registry","cwd":"/tmp","prompt":"what projects have we been working on recently?"}'
OUTPUT_REG=$(echo "$INPUT_REG" | "${VENV_PY}" "${HOOK}")

# Step 3: Assert Recent Projects block exists AND contains the registry token
# Must check both: section exists AND token is in that section
CHECK_REG=$(echo "$OUTPUT_REG" | python3 -c "
import sys, json
import re
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    # Check for Recent Projects section
    if '## Recent Projects' not in ctx:
        print('FAIL: Recent Projects section not found')
        sys.exit(1)
    # Extract ONLY the Recent Projects block (not the whole context)
    match = re.search(r'## Recent Projects.*?(?=## |\Z)', ctx, re.DOTALL)
    if not match:
        print('FAIL: Could not extract Recent Projects block')
        sys.exit(1)
    recent_block = match.group(0)
    # Check for token ONLY in Recent Projects block
    if '${REGISTRY_TOKEN}' in recent_block:
        print('PASS')
    else:
        print('FAIL: registry token not found in Recent Projects block')
        print('Block was:', recent_block[:300])
        sys.exit(1)
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" || echo "FAIL: python error")
[ "$CHECK_REG" = "PASS" ] || fail "$CHECK_REG"
ok "Global Project Registry returns Recent Projects section with p009"

echo "==> Hook mock: project override retrieves from project (E2E semantic test)"
# Step 1: Write a unique memory into project p009_memory_fabric_global with HIGH importance
# This ensures it ranks at the top of results
UNIQUE_TOKEN="OVERRIDE_E2E_TOKEN_$(date +%s)"
"${WRAPPER}" write "${UNIQUE_TOKEN}" --type note --source "p009_memory_fabric_global" --importance 0.9 >/dev/null || fail "write override token"
echo "Wrote unique token: ${UNIQUE_TOKEN}"

# Step 2: From /tmp, call hook with prompt mentioning the project
INPUT3='{"hookEventName":"UserPromptSubmit","session_id":"doctor-e2e","cwd":"/tmp","prompt":"status of p009_memory_fabric_global"}'
OUTPUT3=$(echo "$INPUT3" | "${VENV_PY}" "${HOOK}")

# Step 3: Assert the unique token appears ONLY in the "## Relevant Memories" section
# This is critical: Recent Projects block may contain old tokens, so we must check Relevant Memories
CHECK_E2E=$(echo "$OUTPUT3" | python3 -c "
import sys, json
import re
try:
    d = json.loads(sys.stdin.read())
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    # Extract ONLY the Relevant Memories block
    # Start at '## Relevant Memories' and stop at next ## header or end
    match = re.search(r'## Relevant Memories.*?(?=## |\Z)', ctx, re.DOTALL)
    if not match:
        print('FAIL: Relevant Memories section not found')
        print('Context:', ctx[:500])
        sys.exit(1)
    relevant_block = match.group(0)
    token = '${UNIQUE_TOKEN}'
    if token in relevant_block:
        print('PASS')
    else:
        print('FAIL: unique token not found in Relevant Memories')
        print('Relevant Memories was:', relevant_block[:500])
        sys.exit(1)
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" || echo "FAIL: python error")
[ "$CHECK_E2E" = "PASS" ] || fail "$CHECK_E2E"
ok "Project override retrieves from target project (E2E semantic test)"

echo "✅ Doctor PASS"
