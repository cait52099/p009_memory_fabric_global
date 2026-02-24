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

echo "✅ Doctor PASS"
