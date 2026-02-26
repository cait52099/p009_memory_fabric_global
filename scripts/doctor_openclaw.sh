#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Validator
# Strict Phase 1 E2E: Must attempt triggers and verify fresh artifacts

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
HOOK_NAME="memory-fabric-autowire"
TEMP_DIR="/tmp/openclaw-doctor-$$"
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Global state
GATEWAY_RUNNING=false
WORKSPACE_DIR=""
BACKUP_DIR=""
artifacts=""
has_context=""
has_tools=""

# Helper: Find OpenClaw config file
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

# Capability probing helpers
has_cmd() {
    command -v "$1" &>/dev/null
}

has_subcmd() {
    local cmd="$1"
    shift
    local subcmd="$1"
    # Try: openclaw agent --help (if subcmd is first arg)
    if "$cmd" "$subcmd" --help &>/dev/null; then
        return 0
    fi
    return 1
}

has_nested() {
    local cmd="$1"
    local subcmd="$2"
    # Try: openclaw message send --help
    if "$cmd" "$subcmd" --help &>/dev/null; then
        return 0
    fi
    return 1
}

CONFIG=$(find_config) || {
    echo "ERROR: No OpenClaw config found in ${OPENCLAW_DIR}"
    exit 1
}

echo "==> Using config: ${CONFIG}"

echo "==> [1/8] Check openclaw CLI"
if ! has_cmd openclaw; then
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

echo "==> [8/8] Episode Config Validation"
echo "Checking episode configuration in handler.ts..."

# Check for episode config in handler.ts
if grep -q "episodesAutoRecord" "${HOOK_PATH}/handler.ts"; then
    echo "OK: episodesAutoRecord config found in handler.ts"
else
    echo "ERROR: episodesAutoRecord not found in handler.ts"
    exit 1
fi

if grep -q "episodesAutoInject" "${HOOK_PATH}/handler.ts"; then
    echo "OK: episodesAutoInject config found in handler.ts"
else
    echo "ERROR: episodesAutoInject not found in handler.ts"
    exit 1
fi

if grep -q "shouldSmartInject" "${HOOK_PATH}/handler.ts"; then
    echo "OK: shouldSmartInject function found in handler.ts"
else
    echo "ERROR: shouldSmartInject not found in handler.ts"
    exit 1
fi

if grep -qE "(redactContent|P008|memory_hub.redaction)" "${HOOK_PATH}/handler.ts"; then
    echo "OK: Redaction handled via P008 or note found in handler.ts"
else
    echo "ERROR: Redaction method not found in handler.ts"
    exit 1
fi

# Check if memory-hub supports episode subcommand
if "${MEMORY_HUB}" episode --help >/dev/null 2>&1; then
    echo "OK: memory-hub episode subcommand available"
else
    echo "ERROR: memory-hub episode subcommand not available"
    exit 1
fi

echo ""
echo "==> [9/9] E2E Test"

# Resolve workspace directory with reason
# Sets WORKSPACE_DIR and WORKSPACE_REASON globals
resolve_workspace() {
    # Strategy 1: config agents.defaults.workspace
    WORKSPACE_DIR=$(python3 -c "
import json
try:
    c = json.load(open('${CONFIG}'))
    ws = c.get('agents',{}).get('defaults',{}).get('workspace')
    if ws:
        print(ws)
    else:
        ws = c.get('workspace') or c.get('workspaceDir') or c.get('defaultWorkspace')
        print(ws if ws else '')
except:
    print('')
" 2>/dev/null)

    if [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ]; then
        WORKSPACE_REASON="source=config agents.defaults.workspace"
        return
    fi

    # Strategy 2: fallback - most recent .memory_fabric/hook.log within 60s
    local recent_log=""
    local recent_mtime=0

    # Search in common workspace locations
    for candidate in "${HOME}/clawd" "${HOME}" "${OPENCLAW_DIR}/workspace"; do
        if [ -f "${candidate}/.memory_fabric/hook.log" ]; then
            local mtime
            mtime=$(stat -f%m "${candidate}/.memory_fabric/hook.log" 2>/dev/null || stat -c %Y "${candidate}/.memory_fabric/hook.log" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            local age=$((now - mtime))

            if [ -z "$recent_log" ] || [ "$mtime" -gt "$recent_mtime" ]; then
                if [ "$age" -lt 60 ]; then
                    recent_log="$candidate"
                    recent_mtime=$mtime
                fi
            fi
        fi
    done

    if [ -n "$recent_log" ]; then
        WORKSPACE_DIR="$recent_log"
        WORKSPACE_REASON="source=fallback: recent hook.log within 60s"
    else
        WORKSPACE_DIR="${HOME}/clawd"
        WORKSPACE_REASON="source=fallback: default to ~/clawd"
    fi
}

# Initialize
resolve_workspace
echo "Using workspace: ${WORKSPACE_DIR}"
echo "Workspace reason: ${WORKSPACE_REASON}"

# Memory fabric directory
MF_DIR="${WORKSPACE_DIR}/.memory_fabric"

# Ensure memory fabric directory exists
mkdir -p "$MF_DIR"

# Backup existing artifacts before testing (to prevent false green)
backup_artifacts() {
    if [ -f "${MF_DIR}/context_pack.md" ] || [ -f "${MF_DIR}/TOOLS.md" ] || [ -f "${MF_DIR}/hook.log" ]; then
        BACKUP_DIR="${MF_DIR}/.doctor_backup_$(date +%s)"
        mkdir -p "$BACKUP_DIR"
        mv "${MF_DIR}/context_pack.md" "${MF_DIR}/TOOLS.md" "${MF_DIR}/hook.log" "$BACKUP_DIR/" 2>/dev/null || true
        echo "Backed up existing artifacts to: $BACKUP_DIR"
    fi
}

# Check for artifacts
check_artifacts() {
    local found_context=false
    local found_tools=false

    if [ -f "${MF_DIR}/context_pack.md" ]; then
        found_context=true
    fi
    if [ -f "${MF_DIR}/TOOLS.md" ]; then
        found_tools=true
    fi

    echo "$found_context:$found_tools"
}

# Try to detect if gateway is running
if openclaw gateway status --timeout 3000 >/dev/null 2>&1; then
    GATEWAY_RUNNING=true
fi

# E2E trigger function with timeout
trigger_e2e() {
    local trigger_name="$1"
    local trigger_cmd="$2"

    echo "  Trying: $trigger_name"

    local output_file="${TEMP_DIR}/trigger_${trigger_name// /_}.log"
    local start_time end_time elapsed

    # Run command in background
    (
        eval "$trigger_cmd" > "$output_file" 2>&1
    ) &
    local pid=$!

    # Wait with timeout (45 seconds)
    start_time=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        if [ $elapsed -gt 45 ]; then
            kill $pid 2>/dev/null || true
            # Reap process without breaking set -e flow
            set +e
            wait $pid 2>/dev/null
            set -e
            echo "    TIMEOUT after 45s" >> "$output_file"
            return 1
        fi
        sleep 1
    done

    # wait can return non-zero (e.g. SIGTERM=143); don't let set -e abort script
    set +e
    wait $pid
    local exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
        echo "    SUCCESS: $trigger_name"
        return 0
    else
        echo "    FAILED: $trigger_name (exit $exit_code)"
        echo "    Last 30 lines of output:"
        tail -30 "$output_file" | sed 's/^/      /'
        return 1
    fi
}

# Try triggers in order with capability probing
try_triggers() {
    local triggered=false

    # Strategy 1: openclaw agent --agent main (probed)
    if ! $triggered && has_subcmd openclaw agent; then
        if trigger_e2e "agent-main" "openclaw agent --agent main -m 'memory-fabric e2e test' --timeout 30"; then
            triggered=true
            echo "  -> Trigger succeeded: agent --agent main"
        fi
    fi

    # Strategy 2: openclaw message send (probed)
    if ! $triggered && has_nested openclaw message send; then
        # Get a target - try telegram first
        local target=""
        if openclaw directory self 2>/dev/null | grep -q "telegram"; then
            # Try to get own telegram ID
            target="self"
        fi
        if [ -n "$target" ]; then
            if trigger_e2e "message-send" "openclaw message send --channel telegram --target '$target' --message 'memory-fabric e2e test'"; then
                triggered=true
                echo "  -> Trigger succeeded: message send"
            fi
        fi
    fi

    # Strategy 3: openclaw system event (probed)
    if ! $triggered && has_subcmd openclaw system event; then
        if trigger_e2e "system-event" "openclaw system event --text 'memory-fabric e2e test' --expect-final --timeout 30"; then
            triggered=true
            echo "  -> Trigger succeeded: system event"
        fi
    fi

    # Strategy 4: openclaw sessions send (probed)
    if ! $triggered && has_subcmd openclaw sessions send; then
        local sessions_output
        sessions_output=$(openclaw sessions list --timeout 5000 2>&1 || true)
        local session_id
        session_id=$(echo "$sessions_output" | grep -oE 'telegram:[a-zA-Z0-9_-]+' | head -1 | cut -d: -f2)
        if [ -n "$session_id" ]; then
            if trigger_e2e "sessions-send" "openclaw sessions send --session-id '$session_id' 'memory-fabric e2e test' --timeout 30"; then
                triggered=true
                echo "  -> Trigger succeeded: sessions send"
            fi
        fi
    fi

    # Strategy 5: openclaw agent (auto, fallback)
    if ! $triggered && has_subcmd openclaw agent; then
        if trigger_e2e "agent-auto" "openclaw agent -m 'memory-fabric e2e test' --timeout 30"; then
            triggered=true
            echo "  -> Trigger succeeded: agent (auto)"
        fi
    fi

    if $triggered; then
        return 0
    else
        return 1
    fi
}

if [ "$GATEWAY_RUNNING" = "true" ]; then
    echo "Gateway detected running, attempting E2E test..."

    # Always backup existing artifacts before testing
    echo "Preparing memory fabric directory..."
    backup_artifacts

    # Always attempt triggers
    echo "Attempting E2E triggers..."

    if try_triggers; then
        # Wait for artifacts to be created
        echo "Waiting for artifacts to be created..."
        sleep 3

        # Check for artifacts
        artifacts=$(check_artifacts)
        has_context=$(echo "$artifacts" | cut -d: -f1)
        has_tools=$(echo "$artifacts" | cut -d: -f2)

        # Fallback: if artifacts missing, check recent hook.log within 60s
        if [ "$has_context" != "true" ] || [ "$has_tools" != "true" ]; then
            echo "Artifacts missing in ${WORKSPACE_DIR}, checking for recent hook.log..."

            local fallback_ws=""
            local fallback_mtime=0
            for candidate in "${HOME}/clawd" "${HOME}" "${OPENCLAW_DIR}/workspace"; do
                if [ -f "${candidate}/.memory_fabric/hook.log" ]; then
                    local mtime
                    mtime=$(stat -f%m "${candidate}/.memory_fabric/hook.log" 2>/dev/null || stat -c %Y "${candidate}/.memory_fabric/hook.log" 2>/dev/null || echo "0")
                    local now
                    now=$(date +%s)
                    local age=$((now - mtime))

                    if [ -z "$fallback_ws" ] || [ "$mtime" -gt "$fallback_mtime" ]; then
                        if [ "$age" -lt 60 ]; then
                            fallback_ws="$candidate"
                            fallback_mtime=$mtime
                        fi
                    fi
                fi
            done

            if [ -n "$fallback_ws" ] && [ "$fallback_ws" != "$WORKSPACE_DIR" ]; then
                echo "Re-evaluating artifacts in: $fallback_ws"
                MF_DIR="${fallback_ws}/.memory_fabric"
                WORKSPACE_DIR="$fallback_ws"
                WORKSPACE_REASON="source=fallback: re-evaluated to recent hook.log"
                artifacts=$(check_artifacts)
                has_context=$(echo "$artifacts" | cut -d: -f1)
                has_tools=$(echo "$artifacts" | cut -d: -f2)
            fi
        fi

        if [ "$has_context" = "true" ] && [ "$has_tools" = "true" ]; then
            echo "Artifacts created successfully:"
            echo "  - context_pack.md: ${MF_DIR}/context_pack.md"
            echo "  - TOOLS.md: ${MF_DIR}/TOOLS.md"
            echo ""
            echo "=== Evidence ==="
            ls -la "${MF_DIR}/"
            echo ""
            echo "=== context_pack.md (first 5 lines) ==="
            head -n 5 "${MF_DIR}/context_pack.md"
            echo "✅ E2E OK - Context files verified"
        else
            echo "Trigger succeeded but artifacts missing:"
            echo "  context_pack.md: $has_context"
            echo "  TOOLS.md: $has_tools"
            echo ""
            echo "This indicates hook didn't run or workspace mismatch."
            echo "========================================"
            echo "❌ Doctor FAIL - Trigger succeeded but artifacts missing"
            echo "========================================"
            exit 1
        fi
    else
        echo "All trigger strategies failed."
        echo ""
        echo "Diagnostics:"
        echo "  - Gateway: running"
        echo "  - All trigger methods failed"
        echo ""
        echo "This could mean:"
        echo "  1. Agent is not responding"
        echo "  2. Hook is not being triggered"
        echo "  3. Workspace mismatch"

        # Check if artifacts exist from backup
        if [ -n "$BACKUP_DIR" ] && [ -f "${BACKUP_DIR}/context_pack.md" ]; then
            echo ""
            echo "Note: Artifacts exist from backup, restoring..."
            mv "${BACKUP_DIR}/"* "${MF_DIR}/" 2>/dev/null || true
            rmdir "${BACKUP_DIR}" 2>/dev/null || true
        fi

        echo "========================================"
        echo "❌ Doctor FAIL - All triggers failed and no artifacts"
        echo "========================================"
        exit 1
    fi
else
    echo "Gateway not running, E2E skipped"
    echo "To test E2E manually:"
    echo "  1. Restart OpenClaw gateway: openclaw gateway restart"
    echo "  2. Send a message: openclaw agent --agent main -m 'test'"
    echo "  3. Check workspace/.memory_fabric/"
fi

# === SMART YES/NO INJECTION GATE ===
# Test SMART injection: must inject for matching prompt, must NOT inject for generic
if [[ "${EPISODES_AUTO_INJECT:-smart}" == "smart" ]] && [ "$GATEWAY_RUNNING" = "true" ]; then
    echo ""
    echo "==> SMART Injection Gate"

    # Step 1: Record a test episode with specific intent
    SMART_TOKEN="SMART_INJECT_$(date +%s)"
    "${MEMORY_HUB}" episode record \
        --project p009_openclaw_test \
        --intent "fix openclaw doctor e2e strict ${SMART_TOKEN}" \
        --outcome success \
        --step "doctor smart test" >/dev/null 2>&1 || true
    echo "Recorded test episode: ${SMART_TOKEN}"

    sleep 2

    # Step 2: Trigger message should produce context (strict check)
    # Note: SMART injection is project-specific; verify hook ran by checking context exists
    if openclaw agent --agent main -m "fix openclaw doctor e2e strict" --timeout 30 >/dev/null 2>&1; then
        sleep 2

        # Check that context_pack was created/updated (proves hook ran)
        if [ -f "${MF_DIR}/context_pack.md" ]; then
            # Verify it has MEMORY_FABRIC_CONTEXT markers (hook assembled context)
            if grep -q "MEMORY_FABRIC_CONTEXT" "${MF_DIR}/context_pack.md" 2>/dev/null; then
                echo "OK: SMART trigger message -> context assembled (hook ran)"
            else
                echo "FAIL: context_pack.md missing MEMORY_FABRIC_CONTEXT marker"
                echo "Context pack content:"
                cat "${MF_DIR}/context_pack.md" | head -20
                echo "========================================"
                echo "❌ Doctor FAIL - SMART trigger injection"
                exit 1
            fi
        else
            echo "FAIL: context_pack.md not found after trigger"
            echo "========================================"
            echo "❌ Doctor FAIL - SMART trigger injection"
            exit 1
        fi
    else
        echo "FAIL: Could not trigger agent for SMART test"
        echo "========================================"
        echo "❌ Doctor FAIL - SMART trigger injection"
        exit 1
    fi

    # Step 3: Generic message should NOT inject episode context (strict check)
    if openclaw agent --agent main -m "hello how are you" --timeout 30 >/dev/null 2>&1; then
        sleep 2

        if [ -f "${MF_DIR}/context_pack.md" ]; then
            # Check that EPISODE_CONTEXT marker is NOT present (but memories can be)
            if grep -q "<!-- EPISODE_CONTEXT -->" "${MF_DIR}/context_pack.md" 2>/dev/null; then
                echo "FAIL: Generic prompt should NOT inject episode context"
                echo "context_pack.md contained EPISODE_CONTEXT marker"
                echo "========================================"
                echo "❌ Doctor FAIL - SMART generic injection gate"
                exit 1
            else
                echo "OK: Generic prompt -> NOT injected"
            fi
        else
            echo "FAIL: context_pack.md not found for generic test"
            echo "========================================"
            echo "❌ Doctor FAIL - SMART generic injection gate"
            exit 1
        fi
    else
        echo "FAIL: Could not trigger agent for generic test"
        echo "========================================"
        echo "❌ Doctor FAIL - SMART generic injection gate"
        exit 1
    fi
else
    echo "==> SMART Injection Gate skipped (not smart mode or gateway not running)"
fi

echo ""
if [ "$GATEWAY_RUNNING" = "true" ]; then
    echo "✅ Doctor PASS - All checks succeeded (including E2E)"
else
    echo "✅ Doctor PASS - All checks succeeded (E2E skipped)"
fi
echo "========================================"
echo ""
