#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"
CLAUDE_DIR="${HOME_DIR}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOKS_DST="${CLAUDE_DIR}/hooks/memory_fabric"

echo "==> Remove hooks directory (keeps backups)"
rm -rf "${HOOKS_DST}" || true

echo "==> Restore latest settings backup if exists"
latest="$(ls -1t "${SETTINGS}.bak."* 2>/dev/null | head -n 1 || true)"
if [ -n "${latest}" ]; then
  cp "${latest}" "${SETTINGS}"
  echo "Restored: ${latest} -> ${SETTINGS}"
else
  echo "No backup found. Leaving settings.json as-is."
fi

echo "==> Uninstall complete."
