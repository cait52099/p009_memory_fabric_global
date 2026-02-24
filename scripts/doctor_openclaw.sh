#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Validator

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
HOOK_DIR="${OPENCLAW_DIR}/hooks/memory-fabric-autowire"
MEMORY_HUB="${HOME}/.local/share/memory-fabric/bin/memory-hub"
TEST_WORKSPACE="/tmp/memory-fabric-test-$$"

echo "==> Check memory-hub CLI"
if [ -x "${MEMORY_HUB}" ]; then
  echo "OK: memory-hub found at ${MEMORY_HUB}"
else
  echo "ERROR: memory-hub not found at ${MEMORY_HUB}"
  exit 1
fi

echo "==> Check hook pack installed"
if [ -d "${HOOK_DIR}" ]; then
  echo "OK: Hook pack directory exists: ${HOOK_DIR}"
  ls -la "${HOOK_DIR}"
else
  echo "ERROR: Hook pack not installed at ${HOOK_DIR}"
  exit 1
fi

echo "==> Check handler.ts exists"
if [ -f "${HOOK_DIR}/handler.ts" ]; then
  echo "OK: handler.ts found"
else
  echo "ERROR: handler.ts not found"
  exit 1
fi

echo "==> Check OpenClaw config"
CONFIG="${OPENCLAW_DIR}/openclaw.json"
if [ -f "${CONFIG}" ]; then
  if grep -q "memory-fabric-autowire" "${CONFIG}"; then
    echo "OK: Hook pack enabled in config"
  else
    echo "WARN: Hook pack not enabled in config (may need install_openclaw.sh)"
  fi
else
  echo "WARN: OpenClaw config not found"
fi

echo "==> Test memory-hub assemble"
TEST_OUTPUT=$("${MEMORY_HUB}" assemble "test query" --max-tokens 100 --json 2>/dev/null || echo '{"error": "failed"}')
if echo "${TEST_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(1 if 'error' in d else 0)"; then
  echo "OK: memory-hub assemble works"
else
  echo "ERROR: memory-hub assemble failed"
  echo "${TEST_OUTPUT}"
  exit 1
fi

echo "==> Test context file creation"
mkdir -p "${TEST_WORKSPACE}/.memory_fabric"
echo "<!-- test -->" > "${TEST_WORKSPACE}/.memory_fabric/test.md"
if [ -f "${TEST_WORKSPACE}/.memory_fabric/test.md" ]; then
  echo "OK: Can create context files in workspace"
else
  echo "ERROR: Cannot create context files"
  exit 1
fi

rm -rf "${TEST_WORKSPACE}"

echo "✅ Doctor PASS - OpenClaw integration ready"
