#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"
CLAUDE_DIR="${HOME_DIR}/.claude"
HOOKS_SRC="${ROOT}/claude/hooks/memory_fabric"
HOOKS_DST="${CLAUDE_DIR}/hooks/memory_fabric"
SETTINGS="${CLAUDE_DIR}/settings.json"

RUNTIME_DIR="${HOME_DIR}/.local/share/memory-fabric"
VENV_DIR="${RUNTIME_DIR}/venv"
WRAP_DIR="${RUNTIME_DIR}/bin"
WRAPPER="${WRAP_DIR}/memory-hub"

RUNTIME_DIR="${HOME_DIR}/.local/share/memory-fabric"
VENV_DIR="${RUNTIME_DIR}/venv"
WRAP_DIR="${RUNTIME_DIR}/bin"
WRAPPER="${WRAP_DIR}/memory-hub"

echo "==> [1/7] Determine P008 location"
P008_INSTALL_METHOD=""
if [ -n "${MEMORY_FABRIC_P008_PATH:-}" ] && [ -d "${MEMORY_FABRIC_P008_PATH}" ]; then
  P008_PATH="${MEMORY_FABRIC_P008_PATH}"
  P008_INSTALL_METHOD="env var (${P008_PATH})"
elif [ -d "${ROOT}/../p008_memory_hub" ]; then
  P008_PATH="${ROOT}/../p008_memory_hub"
  P008_INSTALL_METHOD="relative (${P008_PATH})"
else
  P008_PATH=""
  P008_INSTALL_METHOD="git+https"
fi
echo "  Using P008: ${P008_INSTALL_METHOD}"

echo "==> [2/7] Ensure Claude dirs"
mkdir -p "${CLAUDE_DIR}/hooks"

echo "==> [3/7] Install/Update hooks (copy code, keep cache/logs)"
mkdir -p "${HOOKS_DST}"
cp -f "${HOOKS_SRC}/_util.py" "${HOOKS_DST}/_util.py"
cp -f "${HOOKS_SRC}/user_prompt_submit.py" "${HOOKS_DST}/user_prompt_submit.py"
cp -f "${HOOKS_SRC}/stop.py" "${HOOKS_DST}/stop.py"
cp -f "${HOOKS_SRC}/pre_compact.py" "${HOOKS_DST}/pre_compact.py"
cp -f "${HOOKS_SRC}/session_end.py" "${HOOKS_DST}/session_end.py"
mkdir -p "${HOOKS_DST}/cache" "${HOOKS_DST}/logs"

echo "==> [4/7] Ensure runtime venv + install p008"
mkdir -p "${RUNTIME_DIR}" "${WRAP_DIR}"
if [ ! -x "${VENV_DIR}/bin/python" ]; then
  python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/python" -m pip install -U pip
if [ -n "${P008_PATH}" ]; then
  "${VENV_DIR}/bin/pip" install -e "${P008_PATH}"
else
  echo "  Installing P008 from GitHub..."
  "${VENV_DIR}/bin/pip" install "git+https://github.com/cait52099/p008_memory_hub.git"
fi

echo "==> [5/7] Ensure wrapper ${WRAPPER}"

# Auto-detect the correct CLI module entrypoint (robust across p008 changes)
ENTRYPOINT_MODULE=""
CANDIDATES=("cli.commands" "memory_hub.cli" "memory_hub.cli.main")

for mod in "${CANDIDATES[@]}"; do
  if "${VENV_DIR}/bin/python" -m "${mod}" --help >/dev/null 2>&1; then
    ENTRYPOINT_MODULE="${mod}"
    break
  fi
done

if [ -z "${ENTRYPOINT_MODULE}" ]; then
  echo "WARN: could not auto-detect CLI module; falling back to cli.commands" >&2
  ENTRYPOINT_MODULE="cli.commands"
fi

cat > "${WRAPPER}" <<EOF
#!/usr/bin/env bash
exec "${VENV_DIR}/bin/python" -m ${ENTRYPOINT_MODULE} "\$@"
EOF
chmod +x "${WRAPPER}"
"${WRAPPER}" --help >/dev/null

echo "==> [6/7] Patch ~/.claude/settings.json (backup + merge hooks block)"
mkdir -p "${CLAUDE_DIR}"
if [ -f "${SETTINGS}" ]; then
  cp "${SETTINGS}" "${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"
else
  echo "{}" > "${SETTINGS}"
fi

python3 - <<PY
import json, os
from pathlib import Path

home = Path(os.environ["HOME"])
settings = home/".claude/settings.json"
tmpl = Path("${ROOT}")/"claude/templates/hooks_block.json"

data = json.loads(settings.read_text(encoding="utf-8") or "{}")
block = json.loads(tmpl.read_text(encoding="utf-8"))

# Replace hardcoded /Users/caihongwei with $HOME
def replace_home(obj):
    if isinstance(obj, dict):
        return {k: replace_home(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [replace_home(x) for x in obj]
    if isinstance(obj, str):
        return obj.replace("/Users/caihongwei", str(home))
    return obj

block = replace_home(block)

data.setdefault("hooks", {})
# Merge/overwrite our four events (idempotent)
for k, v in block["hooks"].items():
    data["hooks"][k] = v

settings.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("settings.json patched with memory_fabric hooks")
PY

echo "==> [7/7] Done. Run doctor:"
echo "  ${ROOT}/scripts/doctor.sh"
