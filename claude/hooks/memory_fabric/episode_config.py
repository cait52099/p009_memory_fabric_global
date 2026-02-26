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

CONFIG_PATH = Path.home() / ".local/share/memory_fabric/config.json"


def get_config(key: str) -> str:
    """
    Get config value with resolution order:
    1. Environment variable
    2. config.json
    3. Default
    """
    # 1. Check environment
    if key in os.environ:
        return os.environ[key]

    # 2. Check config file
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH) as f:
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


def should_smart_inject(prompt: str, log_content: str = "") -> bool:
    """
    Determine if smart injection should trigger.
    Returns True if:
    - prompt matches known intent (simple keyword check), OR
    - log contains error signatures
    """
    prompt_lower = prompt.lower()
    log_lower = log_content.lower()

    # Check for error signatures in log
    for error in ERROR_SIGNATURES:
        if error.lower() in log_lower:
            return True

    # Check for programming/debug keywords in prompt
    debug_keywords = ["fix", "bug", "error", "fail", "exception", "issue", "problem", "broken"]
    if any(kw in prompt_lower for kw in debug_keywords):
        return True

    return False
