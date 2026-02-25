#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Validator

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
CONFIG="${OPENCLAW_DIR}/openclaw.json"
HOOK_NAME="memory-fabric-autowire"
TEST_WORKSPACE="/tmp/memory-fabric-test-$$"

echo "==> [1/7] Check openclaw CLI"
if ! command -v openclaw &> /dev/null; then
  echo "ERROR: openclaw CLI not found"
  exit 1
fi
echo "OK: openclaw CLI found"

echo "==> [2/7] Check hook pack installed"
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

echo "==> [3/7] Verify hook in openclaw hooks list"
# Hook name may have emoji prefix, use case-insensitive match
HOOKS_OUTPUT=$(openclaw hooks list 2>&1 || true)
if echo "$HOOKS_OUTPUT" | grep -qi "memory-fabric"; then
  echo "OK: Hook appears in 'openclaw hooks list'"
else
  echo "ERROR: Hook '${HOOK_NAME}' not found in hooks list"
  echo "DEBUG: $HOOKS_OUTPUT"
  exit 1
fi

echo "==> [4/7] Verify hook info"
if openclaw hooks info "${HOOK_NAME}" 2>&1 | grep -q "Ready"; then
  echo "OK: Hook is ready"
else
  echo "ERROR: Hook is not ready"
  exit 1
fi

echo "==> [5/7] Verify config - hooks.internal.enabled=true"
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

echo "==> [6/7] Verify hook is enabled in config"
HOOK_ENABLED=$(python3 -c "import json; c=json.load(open('${CONFIG}')); print(c.get('hooks',{}).get('internal',{}).get('entries',{}).get('${HOOK_NAME}',{}).get('enabled', False))" 2>/dev/null || echo "False")
if [ "${HOOK_ENABLED}" = "True" ]; then
  echo "OK: ${HOOK_NAME} is enabled in config"
else
  echo "ERROR: ${HOOK_NAME} is NOT enabled in config"
  exit 1
fi

echo "==> [7/7] Check memory-hub CLI"
MEMORY_HUB="${HOME}/.local/share/memory-fabric/bin/memory-hub"
if [ -x "${MEMORY_HUB}" ]; then
  echo "OK: memory-hub found at ${MEMORY_HUB}"
else
  echo "ERROR: memory-hub not found at ${MEMORY_HUB}"
  exit 1
fi

# Quick functional test
if "${MEMORY_HUB}" --help >/dev/null 2>&1; then
  echo "OK: memory-hub CLI works"
else
  echo "ERROR: memory-hub CLI failed"
  exit 1
fi

echo ""
echo "========================================"
echo "✅ Doctor PASS - All checks succeeded"
echo "========================================"
echo ""
echo "To test E2E:"
echo "1. Restart OpenClaw gateway if running"
echo "2. Send a message to an agent"
echo "3. Check workspace/.memory_fabric/context_pack.md"
echo ""
