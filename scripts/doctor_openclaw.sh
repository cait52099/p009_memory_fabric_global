#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Validator

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
HOOK_NAME="memory-fabric-autowire"
TEST_WORKSPACE="/tmp/memory-fabric-test-$$"

# Helper: Find OpenClaw config file (in order of preference)
find_config() {
    local config_candidates=(
        "${OPENCLAW_DIR}/config.json"
        "${OPENCLAW_DIR}/openclaw.json"
        "${OPENCLAW_DIR}/clawdbot.json"
    )

    for cfg in "${config_candidates[@]}"; do
        if [ -f "$cfg" ]; then
            echo "$cfg"
            return 0
        fi
    done

    return 1
}

CONFIG=$(find_config) || {
    echo "ERROR: No OpenClaw config found in ${OPENCLAW_DIR}"
    echo "Tried: config.json, openclaw.json, clawdbot.json"
    exit 1
}

echo "==> Using config: ${CONFIG}"

echo "==> [1/8] Check openclaw CLI"
if ! command -v openclaw &> /dev/null; then
  echo "ERROR: openclaw CLI not found"
  exit 1
fi
echo "OK: openclaw CLI found"

echo "==> [2/8] Check hook pack installed"
HOOK_PATH="${OPENCLAW_DIR}/hooks/${HOOK_NAME}"
if [ -d "${HOOK_PATH}" ]; then
  echo "OK: Hook directory exists: ${HOOK_PATH}"
else
  echo "ERROR: Hook not installed at ${HOOK_PATH}"
  exit 1
fi

if [ -f "${HOOK_PATH}/handler.ts" ]; then
  echo "OK: handler.ts found"
else
  echo "ERROR: handler.ts not found"
  exit 1
fi

echo "==> [3/8] Verify hook in openclaw hooks list"
HOOKS_OUTPUT=$(openclaw hooks list 2>&1 || true)
if echo "$HOOKS_OUTPUT" | grep -qi "memory-fabric"; then
  echo "OK: Hook appears in 'openclaw hooks list'"
else
  echo "ERROR: Hook '${HOOK_NAME}' not found in hooks list"
  echo "DEBUG: $HOOKS_OUTPUT"
  exit 1
fi

echo "==> [4/8] Verify hook info"
if openclaw hooks info "${HOOK_NAME}" 2>&1 | grep -q "Ready"; then
  echo "OK: Hook is ready"
else
  echo "ERROR: Hook is not ready"
  exit 1
fi

echo "==> [5/8] Verify config - hooks.internal.enabled=true"
if [ -f "${CONFIG}" ]; then
  INTERNAL_ENABLED=$(python3 -c "import json; c=json.load(open('${CONFIG}')); print(c.get('hooks',{}).get('internal',{}).get('enabled', False))")
  if [ "${INTERNAL_ENABLED}" = "True" ]; then
    echo "OK: hooks.internal.enabled = true"
  else
    echo "ERROR: hooks.internal.enabled is not true"
    exit 1
  fi
else
  echo "ERROR: Config file not found: ${CONFIG}"
  exit 1
fi

echo "==> [6/8] Verify hook is enabled in config"
HOOK_ENABLED=$(python3 -c "import json; c=json.load(open('${CONFIG}')); print(c.get('hooks',{}).get('internal',{}).get('entries',{}).get('${HOOK_NAME}',{}).get('enabled', False))" 2>/dev/null || echo "False")
if [ "${HOOK_ENABLED}" = "True" ]; then
  echo "OK: ${HOOK_NAME} is enabled in config"
else
  echo "ERROR: ${HOOK_NAME} is NOT enabled in config"
  exit 1
fi

echo "==> [7/8] Check memory-hub CLI"
MEMORY_HUB="${HOME}/.local/share/memory-fabric/bin/memory-hub"
if [ -x "${MEMORY_HUB}" ]; then
  echo "OK: memory-hub found at ${MEMORY_HUB}"
else
  echo "ERROR: memory-hub not found at ${MEMORY_HUB}"
  exit 1
fi

if "${MEMORY_HUB}" --help >/dev/null 2>&1; then
  echo "OK: memory-hub CLI works"
else
  echo "ERROR: memory-hub CLI failed"
  exit 1
fi

echo "==> [8/8] E2E Test"
# Try to detect if gateway is running
GATEWAY_RUNNING=false
if openclaw gateway status --timeout 3000 >/dev/null 2>&1; then
  GATEWAY_RUNNING=true
fi

if [ "$GATEWAY_RUNNING" = "true" ]; then
  echo "Gateway detected running, attempting E2E test..."

  # Get workspace directory from config
  WORKSPACE_DIR=$(python3 -c "
import json
try:
    c = json.load(open('${CONFIG}'))
    ws = c.get('workspace') or c.get('workspaceDir') or c.get('defaultWorkspace')
    if ws:
        print(ws)
    else:
        print('${OPENCLAW_DIR}/workspace')
except:
    print('${OPENCLAW_DIR}/workspace')
" 2>/dev/null)

  # Run a quick agent turn
  echo "Running test agent turn..."
  if openclaw agent --local -m "hello" --timeout 30 >/dev/null 2>&1; then
    echo "Agent turn completed"
  else
    echo "E2E FAIL: agent turn failed"
    echo "========================================"
    echo "❌ Doctor FAIL - E2E test failed"
    echo "========================================"
    exit 1
  fi

  # Check for context files
  CONTEXT_FOUND=false
  TOOLS_FOUND=false

  # Check common workspace locations for .memory_fabric
  for check_dir in "${WORKSPACE_DIR}"/*/.memory_fabric "${WORKSPACE_DIR}"/.memory_fabric; do
    if [ -f "${check_dir}/context_pack.md" ] 2>/dev/null; then
      echo "OK: Found context_pack.md in ${check_dir}"
      CONTEXT_FOUND=true
    fi
    if [ -f "${check_dir}/TOOLS.md" ] 2>/dev/null; then
      echo "OK: Found TOOLS.md in ${check_dir}"
      TOOLS_FOUND=true
    fi
  done

  if [ "$CONTEXT_FOUND" = "false" ]; then
    echo "E2E FAIL: context_pack.md not found"
    echo "========================================"
    echo "❌ Doctor FAIL - E2E artifacts missing"
    echo "========================================"
    exit 1
  fi

  echo "✅ E2E OK - Context files verified"
else
  echo "E2E skipped (gateway not running)"
  echo "To test E2E manually:"
  echo "  1. Restart OpenClaw gateway"
  echo "  2. Send a message: openclaw agent --local -m 'test'"
  echo "  3. Check workspace/.memory_fabric/context_pack.md"
fi

echo ""
if [ "$GATEWAY_RUNNING" = "true" ]; then
  echo "✅ Doctor PASS - All checks succeeded (including E2E)"
else
  echo "✅ Doctor PASS - All checks succeeded (E2E skipped)"
fi
echo "========================================"
echo ""
