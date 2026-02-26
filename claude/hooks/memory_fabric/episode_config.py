# Memory Fabric Episode Configuration
# Resolution order: env vars > config.json > defaults

import json
import os
from pathlib import Path
from typing import Optional

# Default configuration
DEFAULTS = {
    "EPISODES_AUTO_RECORD": "1",       # Auto-record on session end
    "EPISODES_AUTO_INJECT": "smart",   # smart|0|1
    "EPISODES_REDACT": "1",            # Redact secrets
    "EPISODES_MAX_TOKENS": "350",      # Max tokens for injection
    "EPISODES_MATCH_K": "3",           # Number of episodes to match
}

# Primary config path: memory-fabric (dash)
# Fallback: memory_fabric (underscore) for backward compatibility
CONFIG_PATH_DASH = Path.home() / ".local/share/memory-fabric/config.json"
CONFIG_PATH_UNDERSCORE = Path.home() / ".local/share/memory_fabric/config.json"


def get_config_path() -> Optional[Path]:
    """Get config path with resolution: dash path first, fallback to underscore."""
    if CONFIG_PATH_DASH.exists():
        return CONFIG_PATH_DASH
    if CONFIG_PATH_UNDERSCORE.exists():
        return CONFIG_PATH_UNDERSCORE
    return None


def get_config(key: str) -> str:
    """
    Get config value with resolution order:
    1. Environment variable
    2. config.json (dash path preferred, underscore fallback)
    3. Default
    """
    # 1. Check environment
    if key in os.environ:
        return os.environ[key]

    # 2. Check config file(s)
    config_path = get_config_path()
    if config_path:
        try:
            with open(config_path) as f:
                config = json.load(f)
                if key in config:
                    return str(config[key])
        except (json.JSONDecodeError, IOError):
            pass

    # 3. Return default
    return DEFAULTS.get(key, "")


def get_episodes_auto_record() -> bool:
    """Check if auto-record is enabled."""
    return get_config("EPISODES_AUTO_RECORD") == "1"


def get_episodes_auto_inject() -> str:
    """Get auto-inject mode: smart|0|1"""
    return get_config("EPISODES_AUTO_INJECT")


def get_episodes_redact() -> bool:
    """Check if redaction is enabled."""
    return get_config("EPISODES_REDACT") == "1"


def get_episodes_max_tokens() -> int:
    """Get max tokens for episode injection."""
    try:
        return int(get_config("EPISODES_MAX_TOKENS"))
    except ValueError:
        return 350


def get_episodes_match_k() -> int:
    """Get number of episodes to match."""
    try:
        return int(get_config("EPISODES_MATCH_K"))
    except ValueError:
        return 3


# Known error signatures for smart injection
ERROR_SIGNATURES = [
    "HTTP 401",
    "HTTP 403",
    "fts5",
    "false green",
    "data loss",
    "authentication failed",
    "permission denied",
    "not found",
    "timeout",
    "connection refused",
]


def should_smart_inject(prompt: str, project_id: str = "", log_content: str = "") -> bool:
    """
    Determine if smart injection should trigger (episode-match driven).

    Returns True if:
    (A) Episode match exists for this prompt via memory-hub episode match --k >=1
    OR (B) Error signature match in prompt/log (secondary trigger)

    Falls back to keyword heuristic only if episode match fails.
    """
    import subprocess

    prompt_lower = prompt.lower()
    log_lower = log_content.lower() if log_content else ""

    # Strategy A: Try episode match first
    if project_id and project_id not in ("tmp", "default", ""):
        try:
            result = subprocess.run(
                ["memory-hub", "episode", "match",
                 "--project", project_id,
                 "--prompt", prompt,
                 "--k", "1",
                 "--json"],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                import json
                try:
                    matches = json.loads(result.stdout.strip())
                    if isinstance(matches, list) and len(matches) >= 1:
                        return True
                    # Handle if matches is dict with 'matches' key
                    if isinstance(matches, dict) and matches.get("matches"):
                        return True
                except (json.JSONDecodeError, ValueError):
                    pass
        except Exception:
            pass  # Fall through to error signature check

    # Strategy B: Error signature match (secondary trigger)
    for error in ERROR_SIGNATURES:
        if error.lower() in prompt_lower or error.lower() in log_lower:
            return True

    return False
