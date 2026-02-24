#!/usr/bin/env bash
set -euo pipefail

# Memory Fabric - OpenClaw Integration Installer

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_DIR="${HOME}/.openclaw"
HOOK_SRC="${ROOT}/openclaw/hooks/memory-fabric-autowire"
HOOK_DST="${OPENCLAW_DIR}/hooks/memory-fabric-autowire"
CONFIG="${OPENCLAW_DIR}/openclaw.json"

echo "==> [1/4] Check OpenClaw installation"
if [ ! -d "${OPENCLAW_DIR}" ]; then
  echo "ERROR: OpenClaw not found at ${OPENCLAW_DIR}"
  echo "Please install OpenClaw first: https://github.com/anthropics/openclaw"
  exit 1
fi
echo "OK: OpenClaw directory exists"

echo "==> [2/4] Backup existing config"
if [ -f "${CONFIG}" ]; then
  cp "${CONFIG}" "${CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
  echo "Backed up: ${CONFIG}"
fi

echo "==> [3/4] Install hook pack"
mkdir -p "${HOOK_DST}"
cp -r "${HOOK_SRC}"/* "${HOOK_DST}/"
echo "Installed: ${HOOK_DST}"

echo "==> [4/4] Enable hook pack in config"
# Check if hooks section exists, add if not
python3 - <<PY
import json
import os

config_path = os.environ["CONFIG"]
with open(config_path, 'r') as f:
    config = json.load(f)

# Add hook pack reference
config.setdefault("hookPacks", [])
hook_ref = {
    "name": "memory-fabric-autowire",
    "enabled": True,
    "path": os.environ["HOOK_DST"]
}

# Check if already exists
exists = any(h.get("name") == "memory-fabric-autowire" for h in config["hookPacks"])
if not exists:
    config["hookPacks"].append(hook_ref)

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print("Config updated with memory-fabric-autowire hook pack")
PY

echo "==> Done. Run doctor:"
echo "  ${ROOT}/scripts/doctor_openclaw.sh"
