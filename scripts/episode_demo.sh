#!/usr/bin/env bash
set -euo pipefail

# Episode Demo Script - validates episode functionality in P009
# Only runs when MEMORY_FABRIC_EPISODES_DEMO=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"
WRAPPER="${HOME_DIR}/.local/share/memory-fabric/bin/memory-hub"
PROJECT_ID="p009_memory_fabric_global"

# Helper functions
fail() {
    echo "FAIL: $1" >&2
    exit 1
}

ok() {
    echo "OK: $1"
}

# Check if demo is enabled
if [[ "${MEMORY_FABRIC_EPISODES_DEMO:-0}" != "1" ]]; then
    echo "SKIP: MEMORY_FABRIC_EPISODES_DEMO not set to 1"
    exit 0
fi

echo "==> Episode Demo (MEMORY_FABRIC_EPISODES_DEMO=1)"

# Generate unique tokens with timestamp
TIMESTAMP=$(date +%s)
SUCCESS_TOKEN="EP_SUCCESS_${TIMESTAMP}"
FAIL_TOKEN="EP_FAIL_${TIMESTAMP}"

# Use temp directory for test data
TEST_DATA_DIR=$(mktemp -d)
trap "rm -rf ${TEST_DATA_DIR}" EXIT

echo "==> Recording success episode"
"${WRAPPER}" --data-dir "${TEST_DATA_DIR}" episode record \
    --project "${PROJECT_ID}" \
    --intent "Add feature X for testing" \
    --outcome success \
    --attempts 1 \
    --rollbacks 0 \
    --step "First step with ${SUCCESS_TOKEN}" \
    --step "Second step with ${SUCCESS_TOKEN}" \
    --json >/dev/null || fail "failed to record success episode"
ok "success episode recorded"

echo "==> Recording failure episode"
"${WRAPPER}" --data-dir "${TEST_DATA_DIR}" episode record \
    --project "${PROJECT_ID}" \
    --intent "Add feature Y for testing" \
    --outcome failure \
    --attempts 2 \
    --rollbacks 1 \
    --error-signature "false green" \
    --step "First step with ${FAIL_TOKEN}" \
    --json >/dev/null || fail "failed to record failure episode"
ok "failure episode recorded"

echo "==> Testing episode match"
MATCH_OUTPUT=$("${WRAPPER}" --data-dir "${TEST_DATA_DIR}" episode match \
    --project "${PROJECT_ID}" \
    --prompt "Add feature X for testing" \
    --k 5 --json)

echo "${MATCH_OUTPUT}" | python3 -m json.tool >/dev/null || fail "episode match failed to output JSON"

# Check if success token appears
echo "${MATCH_OUTPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = False
for item in data:
    content = json.dumps(item)
    if '${SUCCESS_TOKEN}' in content:
        print('Found success token in match results')
        found = True
        break
if not found:
    sys.exit(1)
" || fail "success episode not found in match results"
ok "episode match finds success episode"

# Check if failure token appears
echo "${MATCH_OUTPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = False
for item in data:
    content = json.dumps(item)
    if '${FAIL_TOKEN}' in content:
        print('Found failure token in match results')
        found = True
        break
if not found:
    sys.exit(1)
" || fail "failure episode not found in match results"
ok "episode match finds failure episode"

echo "==> Testing assemble with episodes"
ASSEMBLE_OUTPUT=$("${WRAPPER}" --data-dir "${TEST_DATA_DIR}" assemble \
    "Add feature" \
    --project "${PROJECT_ID}" \
    --with-episodes)

# Check for Best Known Path section
echo "${ASSEMBLE_OUTPUT}" | grep -q "## Best Known Path" || fail "Best Known Path section missing"
ok "Best Known Path section present"

# Check for Pitfalls section
echo "${ASSEMBLE_OUTPUT}" | grep -q "## Pitfalls to Avoid" || fail "Pitfalls to Avoid section missing"
ok "Pitfalls to Avoid section present"

# Check for success token in Best Known Path
BEST_PATH=$(echo "${ASSEMBLE_OUTPUT}" | sed -n '/## Best Known Path/,/## Pitfalls to Avoid/p')
echo "${BEST_PATH}" | grep -q "${SUCCESS_TOKEN}" || fail "SUCCESS_TOKEN not in Best Known Path"
ok "SUCCESS_TOKEN in Best Known Path"

# Check for failure token in Pitfalls
PITFALLS=$(echo "${ASSEMBLE_OUTPUT}" | sed -n '/## Pitfalls to Avoid/,$p')
echo "${PITFALLS}" | grep -q "${FAIL_TOKEN}" || fail "FAIL_TOKEN not in Pitfalls to Avoid"
ok "FAIL_TOKEN in Pitfalls to Avoid"

echo ""
echo "=========================================="
echo "✅ Episode Demo PASSED"
echo "=========================================="
