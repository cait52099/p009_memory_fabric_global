#!/usr/bin/env python3
from __future__ import annotations
# SessionEnd hook - promote session notes to project memory + global registry + episode auto-record

import json
import subprocess
import sys
import os
from datetime import datetime

# Add hooks dir to path
sys.path.insert(0, os.path.dirname(__file__))

from _util import (
    get_project_id,
    get_session_id,
    run_memory_hub,
    read_cache,
    read_hook_input,
    log_message
)
from episode_config import get_episodes_auto_record, get_episodes_redact

# Try to import P008 redaction module (installed in memory-fabric venv)
REDACT_AVAILABLE = False
try:
    from memory_hub.redaction import redact as redact_text
    REDACT_AVAILABLE = True
except ImportError:
    # Fallback: simple redaction if P008 not available
    import re

    def redact_text(text: str) -> str:
        """Simple fallback redaction if P008 not available."""
        if not text:
            return text
        # Basic patterns
        text = re.sub(r'sk-[a-zA-Z0-9]{20,}', '<REDACTED_TOKEN>', text)
        text = re.sub(r'sk-ant-[a-zA-Z0-9\-_]+', '<REDACTED_TOKEN>', text)
        text = re.sub(r'gh[pousr]_[a-zA-Z0-9]{36,}', '<REDACTED_TOKEN>', text)
        text = re.sub(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[A-Za-z]{2,}', '<REDACTED_EMAIL>', text)
        text = re.sub(r'AKIA[0-9A-Z]{16}', '<REDACTED_AWS_KEY>', text)
        return text


def get_git_remote_url(cwd: str) -> str:
    """Get git remote origin URL if available."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ""


def write_global_registry_snapshot(project_id: str, cwd: str, session_id: str):
    """Write a user-scope snapshot to the global project registry."""
    git_url = get_git_remote_url(cwd)
    timestamp = datetime.now().isoformat()

    # Build compact content: project_id | git_url | timestamp | 1-3 line summary
    cache = read_cache(session_id)
    summary_line = ""
    if cache:
        user_prompt = cache.get("user_prompt", "")
        if user_prompt:
            summary_line = user_prompt[:100].replace("\n", " ")

    # Content format: "project_id | git_url | timestamp | what_was_done"
    content = f"{project_id} | {git_url} | {timestamp} | {summary_line}"

    output, code = run_memory_hub([
        "write",
        content,
        "--type", "project_snapshot",
        "--source", "global:project_registry",
        "--importance", "0.6"
    ])

    if code == 0:
        log_message(f"Global registry snapshot written for {project_id}", session_id)
    else:
        log_message(f"Error writing registry snapshot: {output}", session_id)


def main():
    hook_input = read_hook_input()

    cwd = hook_input.get("cwd", os.getcwd())
    session_id = get_session_id(hook_input)

    project_id = get_project_id(cwd)
    log_message(f"SessionEnd: project={project_id}, session={session_id}", session_id)

    # Write global project registry snapshot
    write_global_registry_snapshot(project_id, cwd, session_id)

    # Read cached session data
    cache = read_cache(session_id)

    if not cache:
        log_message("No cache found, nothing to promote", session_id)
        sys.exit(0)

    # Summarize session - get memories for this session and promote importance
    # Write project-specific summary
    user_prompt = cache.get("user_prompt", "")
    if user_prompt:
        # Write summary to project scope
        summary_content = f"[session-end:{session_id}] Session summary: {user_prompt[:200]}"

        output, code = run_memory_hub([
            "write",
            summary_content,
            "--type", "summary",
            "--source", f"project:{project_id}",
            "--importance", "0.5"
        ])

        if code == 0:
            log_message(f"Session summary written for {session_id}", session_id)
        else:
            log_message(f"Error: {output}", session_id)

    # Auto-record episode if enabled
    if get_episodes_auto_record() and project_id not in ("default", "tmp"):
        try:
            # Build episode record command
            intent_raw = user_prompt[:200] if user_prompt else f"Session {session_id}"
            step_raw = f"Session {session_id} ended"

            # Apply redaction if enabled (default ON)
            if get_episodes_redact():
                intent = redact_text(intent_raw)
                step = redact_text(step_raw)
                log_message(f"SessionEnd: auto-recorded episode for {project_id} (redact=on)", session_id)
            else:
                intent = intent_raw
                step = step_raw
                log_message(f"SessionEnd: auto-recorded episode for {project_id} (redact=off)", session_id)

            cmd = [
                "episode", "record",
                "--project", project_id,
                "--intent", intent,
                "--outcome", "mixed",  # Default to mixed since we don't know outcome
                "--step", step
            ]
            output, code = run_memory_hub(cmd)
        except Exception as e:
            log_message(f"SessionEnd: auto-record failed: {e}", session_id)

    # Clean up cache
    cache_file = os.path.expanduser(f"~/.claude/hooks/memory_fabric/cache/{session_id}.json")
    if os.path.exists(cache_file):
        try:
            os.remove(cache_file)
        except Exception:
            pass

    # Exit without JSON - session end should not block
    sys.exit(0)


if __name__ == "__main__":
    main()
