#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Installer

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
HOOK_SRC="${ROOT}/openclaw/hooks/memory-fabric-autowire"
CONFIG="${OPENCLAW_DIR}/openclaw.json"
HOOK_NAME="memory-fabric-autowire"

echo "==> [1/5] Check OpenClaw installation"
if [ ! -d "${OPENCLAW_DIR}" ]; then
  echo "ERROR: OpenClaw not found at ${OPENCLAW_DIR}"
  echo "Please install OpenClaw first: https://github.com/anthropics/openclaw"
  exit 1
fi
echo "OK: OpenClaw directory exists"

# Check if openclaw CLI is available
if ! command -v openclaw &> /dev/null; then
  echo "ERROR: openclaw CLI not found in PATH"
  exit 1
fi
echo "OK: openclaw CLI available"

echo "==> [2/5] Backup existing config"
if [ -f "${CONFIG}" ]; then
  cp "${CONFIG}" "${CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
  echo "Backed up: ${CONFIG}"
else
  echo "WARN: Config file not found, will create"
fi

echo "==> [3/5] Install hook pack (idempotent)"
# Use openclaw hooks install - handles already-installed gracefully
if openclaw hooks install "${HOOK_SRC}" 2>&1; then
  echo "OK: Hook installed/verified: ${HOOK_NAME}"
else
  # Try manual install if CLI fails
  HOOK_DST="${OPENCLAW_DIR}/hooks/${HOOK_NAME}"
  mkdir -p "${HOOK_DST}"
  cp -r "${HOOK_SRC}"/* "${HOOK_DST}/"
  echo "OK: Hook installed manually to ${HOOK_DST}"
fi

echo "==> [4/5] Enable hook"
if openclaw hooks enable "${HOOK_NAME}" 2>&1; then
  echo "OK: Hook enabled: ${HOOK_NAME}"
else
  echo "WARN: Could not enable via CLI, will patch config directly"
fi

echo "==> [5/5] Ensure config has hooks.internal.enabled=true and hook enabled"
# Ensure hooks.internal.enabled=true in config
python3 - <<PY
import json
import os
from pathlib import Path

config_path = "${CONFIG}"
hook_name = "${HOOK_NAME}"

# Read config
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

# Ensure hooks.internal structure
config.setdefault("hooks", {}).setdefault("internal", {})
hooks_internal = config["hooks"]["internal"]

# Enable internal hooks if not set
if "enabled" not in hooks_internal:
    hooks_internal["enabled"] = True
    print("Set hooks.internal.enabled = true")

# Ensure hook entry exists and is enabled
hooks_internal.setdefault("entries", {}).setdefault(hook_name, {})
if not hooks_internal["entries"][hook_name].get("enabled", False):
    hooks_internal["entries"][hook_name]["enabled"] = True
    print(f"Enabled hook: {hook_name}")

# Write back
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Config updated: {config_path}")
PY

echo "==> Done. Run doctor:"
echo "  ${ROOT}/scripts/doctor_openclaw.sh"
