from __future__ import annotations
from typing import Optional
# Memory Fabric Hook Utilities
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Known projects that can be referenced by name
KNOWN_PROJECTS = frozenset([
    "p009_memory_fabric_global",
    "p008_memory_hub",
    # Add more known projects as needed
])

# Pattern: lowercase alphanumeric, underscores, hyphens, max 80 chars
PROJECT_PATTERN = re.compile(r'^[a-z0-9_\-]{1,80}$')

MEMORY_HUB_BIN = os.path.expanduser("~/.local/share/memory-fabric/bin/memory-hub")
CACHE_DIR = Path(os.path.expanduser("~/.claude/hooks/memory_fabric/cache"))
LOG_DIR = Path(os.path.expanduser("~/.claude/hooks/memory_fabric/logs"))


def get_project_id(cwd: str) -> str:
    """Determine project_id from cwd.

    Always tries git rev-parse first, then falls back to dirname.
    """
    # Always try git rev-parse first (works even in subdirectories)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            git_root = result.stdout.strip()
            if git_root:
                return os.path.basename(git_root)
    except Exception:
        pass

    # Fallback to dirname
    return os.path.basename(cwd.rstrip(os.sep)) or "default"


def extract_project_from_prompt(prompt: str) -> Optional[str]:
    """Extract project name from user prompt.

    Looks for:
    - Known project names (e.g., p009_memory_fabric_global)
    - GitHub URLs containing project slugs

    Returns validated project_id if found and valid, else None.
    """
    if not prompt:
        return None

    # 1. Check for GitHub URLs and extract project slug
    # Pattern: github.com/owner/slug or github.com/owner/slug/...
    gh_pattern = re.compile(r'github\.com/([a-zA-Z0-9_\-]+)/([a-zA-Z0-9_\-]+)')
    gh_match = gh_pattern.search(prompt)
    if gh_match:
        slug = gh_match.group(2)
        if _is_valid_project(slug):
            return slug

    # 2. Check for known project names directly in prompt
    # Look for project-like patterns: alphanumeric with underscores/hyphens
    word_pattern = re.compile(r'\b([a-z][a-z0-9_\-]{2,79})\b')
    for match in word_pattern.finditer(prompt.lower()):
        candidate = match.group(1)
        # Check if it's a known project
        if candidate in KNOWN_PROJECTS:
            return candidate

    return None


def _is_valid_project(name: str) -> bool:
    """Validate project name against strict pattern."""
    if not name:
        return False
    return bool(PROJECT_PATTERN.match(name))


def get_session_id(hook_input: dict) -> str:
    """Extract session_id from hook input."""
    return hook_input.get("session_id", "unknown")


def log_message(message: str, session_id: str = "general"):
    """Log to file."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = LOG_DIR / f"hook_{session_id}.log"
    with open(log_file, "a") as f:
        from datetime import datetime
        f.write(f"[{datetime.now().isoformat()}] {message}\n")


def run_memory_hub(args: list, input_data: str = None) -> tuple[str, int]:
    """Run memory-hub command and return (output, returncode)."""
    try:
        result = subprocess.run(
            [MEMORY_HUB_BIN] + args,
            input=input_data,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout, result.returncode
    except Exception as e:
        return str(e), 1


def read_cache(session_id: str) -> Optional[dict]:
    """Read cached data for session."""
    cache_file = CACHE_DIR / f"{session_id}.json"
    if cache_file.exists():
        try:
            return json.loads(cache_file.read_text())
        except Exception:
            pass
    return None


def write_cache(session_id: str, data: dict):
    """Write cache data for session."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE_DIR / f"{session_id}.json"
    cache_file.write_text(json.dumps(data))


def read_hook_input() -> dict:
    """Read hook JSON input from stdin."""
    try:
        return json.loads(sys.stdin.read())
    except Exception:
        return {}
