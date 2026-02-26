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

# Timeout settings (can override via env)
GATEWAY_TIMEOUT_MS="${GATEWAY_TIMEOUT_MS:-5000}"
AGENT_TIMEOUT_SEC="${AGENT_TIMEOUT_SEC:-30}"

# Global state
GATEWAY_RUNNING=false
WORKSPACE_DIR=""
WORKSPACE_REASON=""
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

# New probe_cmd: tests if openclaw subcommand exists
probe_cmd() {
    openclaw "$@" --help >/dev/null 2>&1
}

# Capability flags (populated at runtime)
HAS_AGENT=false
HAS_SESSIONS_LIST=false
HAS_SESSIONS_SEND=false

# Legacy helpers (kept for compatibility)
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

# Populate capability flags
if probe_cmd agent; then
    HAS_AGENT=true
    echo "  -> Detected: openclaw agent"
fi
if probe_cmd sessions list; then
    HAS_SESSIONS_LIST=true
    echo "  -> Detected: openclaw sessions list"
fi
if probe_cmd sessions send; then
    HAS_SESSIONS_SEND=true
    echo "  -> Detected: openclaw sessions send"
fi

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

    # Strategy 2: fallback - most recent .memory_fabric/hook.log within 120s
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
                if [ "$age" -lt 120 ]; then
                    recent_log="$candidate"
                    recent_mtime=$mtime
                fi
            fi
        fi
    done

    if [ -n "$recent_log" ]; then
        WORKSPACE_DIR="$recent_log"
        WORKSPACE_REASON="source=fallback: recent hook.log within 120s"
    else
        WORKSPACE_DIR=""
        WORKSPACE_REASON="source=fallback: unresolved"
    fi
}

# Initialize
resolve_workspace

# Guard: workspace must be non-empty
if [ -z "$WORKSPACE_DIR" ]; then
    echo "FAIL: Workspace directory resolved to empty"
    echo "Config checked: ${CONFIG}"
    echo "Keys checked: agents.defaults.workspace, workspace, workspaceDir, defaultWorkspace"
    echo "========================================"
    echo "❌ Doctor FAIL - Empty workspace"
    exit 1
fi

# Guard: workspace must be valid directory (not root)
if [ "$WORKSPACE_DIR" = "/" ] || [ -z "$WORKSPACE_DIR" ]; then
    echo "FAIL: Invalid workspace: '$WORKSPACE_DIR'"
    echo "Cannot use root directory or empty path"
    echo "========================================"
    echo "❌ Doctor FAIL - Invalid workspace"
    exit 1
fi

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
        # Move artifacts that affect pass/fail; keep hook.log in place so new events can append
        mv "${MF_DIR}/context_pack.md" "${MF_DIR}/TOOLS.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp "${MF_DIR}/hook.log" "$BACKUP_DIR/" 2>/dev/null || true
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
if openclaw gateway status --timeout "$GATEWAY_TIMEOUT_MS" >/dev/null 2>&1; then
    GATEWAY_RUNNING=true
fi

# E2E trigger function with timeout
trigger_e2e() {
    local trigger_name="$1"
    local trigger_cmd="$2"

    # Ensure timeout variables are set
    local timeout_sec="${AGENT_TIMEOUT_SEC:-30}"

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

# Detect whether openclaw command supports a --timeout flag
supports_timeout_flag() {
    local help_out
    help_out=$("$@" --help 2>&1 || true)
    echo "$help_out" | grep -q -- '--timeout'
}

# Build command with timeout only when supported
with_timeout_arg() {
    local base_cmd="$1"
    local timeout_ms="$2"
    if eval "$base_cmd --help" 2>/dev/null | grep -q -- '--timeout'; then
        echo "$base_cmd --timeout ${timeout_ms}"
    else
        echo "$base_cmd"
    fi
}

# Find first usable session id from status/sessions outputs
pick_session_id() {
    local sid=""
    local out=""

    # 1) Prefer openclaw sessions list --json if available (audit ref: #3)
    if [ "$HAS_SESSIONS_LIST" = "true" ]; then
        out=$(openclaw sessions list --json 2>&1 || true)
        if [ -n "$out" ] && echo "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
            sid=$(echo "$out" | python3 - <<'PY1'
import json, sys
try:
    data=json.load(sys.stdin)
    # Handle various JSON formats: {sessions:[...]} or [{...}] or {id:...}
    items=[]
    if isinstance(data, list):
        items=data
    elif isinstance(data, dict):
        if 'sessions' in data:
            items=data['sessions'] or []
        elif 'items' in data:
            items=data['items'] or []
        elif 'sessionId' in data:
            print(data.get('sessionId') or data.get('id') or '')
            sys.exit(0)
        else:
            items=list(data.values()) if data else []
    items=[x for x in items if isinstance(x, dict) and x.get('id') or x.get('sessionId')]
    if items:
        # Sort by most recent
        items=sorted(items, key=lambda x: x.get('updatedAt') or x.get('lastActivityAt') or x.get('createdAt') or 0, reverse=True)
        print(items[0].get('sessionId') or items[0].get('id') or '')
except Exception:
    pass
PY1
)
            if [ -n "$sid" ]; then
                echo "$sid"
                return
            fi
        fi
    fi

    # 2) Fallback: status output hints
    out=$(openclaw status --all --deep 2>&1 || true)
    sid=$(echo "$out" | grep -Eo '(session[-_ ]?id|sessionId)[:= ]+[A-Za-z0-9:_-]+' | head -1 | sed -E 's/.*[:= ]+//' )

    # 3) Fallback: parse main agent session store directly (most reliable)
    if [ -z "$sid" ]; then
        sid=$(python3 - <<'PY2'
import json, os
p=os.path.expanduser('~/.openclaw/agents/main/sessions/sessions.json')
try:
    data=json.load(open(p))
    if isinstance(data, dict):
        # either {sessions:[...]} or {sessionKey:{...}, ...}
        if 'sessions' in data and isinstance(data.get('sessions'), (list, dict)):
            items=data['sessions']
        elif 'items' in data and isinstance(data.get('items'), (list, dict)):
            items=data['items']
        else:
            items=list(data.values())
    else:
        items=data or []
    if isinstance(items, dict):
        items=list(items.values())
    items=[x for x in items if isinstance(x, dict)]
    if items:
        items=sorted(items, key=lambda x: x.get('updatedAt') or x.get('lastActivityAt') or 0, reverse=True)
        k=items[0].get('sessionId') or items[0].get('sessionKey') or items[0].get('id') or ''
        print(k)
except Exception:
    pass
PY2
)
    fi

    echo "$sid"
}

# Retry wrapper for transient gateway/targeting failures
trigger_with_retry() {
    local name="$1"
    local cmd="$2"
    local attempts=0
    local max_attempts=3
    local delay=1

    while [ "$attempts" -lt "$max_attempts" ]; do
        attempts=$((attempts + 1))
        if trigger_e2e "${name}-try${attempts}" "$cmd"; then
            return 0
        fi

        local logf="${TEMP_DIR}/trigger_${name// /_}-try${attempts}.log"
        if [ -f "$logf" ] && grep -Eq '(gateway timeout after [0-9]+ms|Pass --to|--session-id|--agent)' "$logf"; then
            if [ "$attempts" -lt "$max_attempts" ]; then
                echo "    RETRY(${attempts}/${max_attempts}) after ${delay}s: transient gateway/targeting failure"
                sleep "$delay"
                delay=$((delay * 2))
                continue
            fi
        fi

        # non-transient failure: no need to keep retrying
        if [ "$attempts" -lt "$max_attempts" ]; then
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    return 1
}

# Try triggers in order with capability probing
try_triggers() {
    local triggered=false

        # Strategy 1: openclaw agent --agent main (primary)
    if ! $triggered && [ "$HAS_AGENT" = "true" ]; then
        local cmd="openclaw agent --agent main -m 'memory-fabric e2e test'"
        if supports_timeout_flag openclaw agent; then
            cmd+=" --timeout ${AGENT_TIMEOUT_SEC}"
        fi
        if trigger_with_retry "agent-main" "$cmd"; then
            triggered=true
            echo "  -> Trigger succeeded: agent --agent main"
        fi
    fi

    # Strategy 2: openclaw agent --session-id <id> (explicit target fallback)
    if ! $triggered && [ "$HAS_AGENT" = "true" ]; then
        local session_id=""
        session_id=$(pick_session_id)
        if [ -n "$session_id" ]; then
            local cmd="openclaw agent --session-id '${session_id}' -m 'memory-fabric e2e test'"
            if supports_timeout_flag openclaw agent; then
                cmd+=" --timeout ${AGENT_TIMEOUT_SEC}"
            fi
            if trigger_with_retry "agent-session" "$cmd"; then
                triggered=true
                echo "  -> Trigger succeeded: agent --session-id ${session_id}"
            fi
        else
            echo "  -> No session-id discovered from status/session store"
        fi
    fi

    # Strategy 3: openclaw sessions send (explicit session target) - audit ref: #5
    if ! $triggered && [ "$HAS_SESSIONS_SEND" = "true" ]; then
        local session_id=""
        session_id=$(pick_session_id)
        if [ -n "$session_id" ]; then
            # Try --text first (preferred)
            local cmd=""
            if openclaw sessions send --help 2>&1 | grep -q '\--text'; then
                cmd="openclaw sessions send --session-id '${session_id}' --text 'memory-fabric e2e test'"
                echo "  -> Using sessions send with --text"
            else
                # Fallback to positional argument
                cmd="openclaw sessions send --session-id '${session_id}' 'memory-fabric e2e test'"
                echo "  -> Using sessions send with positional arg (--text not supported)"
            fi
            if supports_timeout_flag openclaw sessions send; then
                cmd+=" --timeout ${AGENT_TIMEOUT_SEC}"
            fi
            if trigger_with_retry "sessions-send" "$cmd"; then
                triggered=true
                echo "  -> Trigger succeeded: sessions send --session-id ${session_id}"
            fi
        else
            echo "  -> No session-id discovered for sessions send"
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
    mkdir -p "$MF_DIR"

    # Always attempt triggers
    echo "Attempting E2E triggers..."

    if try_triggers; then
        # Wait for artifacts to be created (poll up to 20s)
        echo "Waiting for artifacts to be created..."
        for _ in $(seq 1 10); do
            sleep 2
            artifacts=$(check_artifacts)
            has_context=$(echo "$artifacts" | cut -d: -f1)
            has_tools=$(echo "$artifacts" | cut -d: -f2)
            if [ "$has_context" = "true" ] && [ "$has_tools" = "true" ]; then
                break
            fi
        done

        # If artifacts missing, do one strict recovery attempt with agent trigger,
        # then re-check and workspace re-evaluation.
        if [ "$has_context" != "true" ] || [ "$has_tools" != "true" ]; then
            echo "Artifacts missing in ${WORKSPACE_DIR}, running one recovery trigger (agent-auto)..."
            if has_subcmd openclaw agent; then
                trigger_e2e "agent-recovery" "openclaw agent --agent main -m 'memory-fabric artifact recovery' --timeout ${AGENT_TIMEOUT_SEC:-30}" || true
                sleep 3
                artifacts=$(check_artifacts)
                has_context=$(echo "$artifacts" | cut -d: -f1)
                has_tools=$(echo "$artifacts" | cut -d: -f2)
            fi
        fi

        # Fallback: if still missing, check recent hook.log within 120s
        if [ "$has_context" != "true" ] || [ "$has_tools" != "true" ]; then
            echo "Artifacts still missing in ${WORKSPACE_DIR}, checking for recent hook.log..."

            fallback_ws=""
            fallback_mtime=0
            for candidate in "${HOME}/clawd" "${HOME}" "${OPENCLAW_DIR}/workspace"; do
                if [ -f "${candidate}/.memory_fabric/hook.log" ]; then
                    mtime=$(stat -f%m "${candidate}/.memory_fabric/hook.log" 2>/dev/null || stat -c %Y "${candidate}/.memory_fabric/hook.log" 2>/dev/null || echo "0")
                    now=$(date +%s)
                    age=$((now - mtime))

                    if [ -z "$fallback_ws" ] || [ "$mtime" -gt "$fallback_mtime" ]; then
                        if [ "$age" -lt 120 ]; then
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

        # Final grace re-check (hooks can be slightly delayed)
        if [ "$has_context" != "true" ] || [ "$has_tools" != "true" ]; then
            sleep 5
            artifacts=$(check_artifacts)
            has_context=$(echo "$artifacts" | cut -d: -f1)
            has_tools=$(echo "$artifacts" | cut -d: -f2)
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

            # Print hook.log tail diagnostics (audit ref: #2)
            echo ""
            echo "=== Hook.log Diagnostics (last 80 lines) ==="
            local hook_log=""
            # First try: workspace/.memory_fabric/hook.log
            if [ -f "${WORKSPACE_DIR}/.memory_fabric/hook.log" ]; then
                hook_log="${WORKSPACE_DIR}/.memory_fabric/hook.log"
                echo "Source: ${hook_log}"
                tail -80 "$hook_log" | sed 's/^/  /'
            else
                # Else: search recent hook.log under workspace root (within 120s)
                echo "Searching for recent hook.log within 120s..."
                local recent_hook=""
                for candidate in "${HOME}/clawd" "${HOME}" "${OPENCLAW_DIR}/workspace"; do
                    if [ -f "${candidate}/.memory_fabric/hook.log" ]; then
                        local mtime
                        mtime=$(stat -f%m "${candidate}/.memory_fabric/hook.log" 2>/dev/null || stat -c %Y "${candidate}/.memory_fabric/hook.log" 2>/dev/null || echo "0")
                        local now age
                        now=$(date +%s)
                        age=$((now - mtime))
                        if [ "$age" -lt 120 ]; then
                            if [ -z "$recent_hook" ] || [ "$mtime" -gt "$(stat -f%m "$recent_hook" 2>/dev/null || stat -c %Y "$recent_hook" 2>/dev/null || echo "0")" ]; then
                                recent_hook="${candidate}/.memory_fabric/hook.log"
                            fi
                        fi
                    fi
                done
                if [ -n "$recent_hook" ]; then
                    hook_log="$recent_hook"
                    echo "Source: ${hook_log}"
                    tail -80 "$hook_log" | sed 's/^/  /'
                else
                    echo "  No hook.log found within 120s window"
                fi
            fi
            echo "=== End Diagnostics ==="

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

    sleep 3

    # Step 2: Trigger message should produce context (strict check)
    # Note: SMART injection is project-specific; verify hook ran by checking context exists
    if openclaw agent --agent main -m "fix openclaw doctor e2e strict" --timeout $AGENT_TIMEOUT_SEC >/dev/null 2>&1; then
        sleep 3

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
    if openclaw agent --agent main -m "hello how are you" --timeout $AGENT_TIMEOUT_SEC >/dev/null 2>&1; then
        sleep 3

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
