#!/usr/bin/env python3
from __future__ import annotations
# SessionEnd hook - promote session notes to project memory

import json
import sys
import os

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


def main():
    hook_input = read_hook_input()

    cwd = hook_input.get("cwd", os.getcwd())
    session_id = get_session_id(hook_input)

    project_id = get_project_id(cwd)
    log_message(f"SessionEnd: project={project_id}, session={session_id}", session_id)

    # Read cached session data
    cache = read_cache(session_id)

    if not cache:
        log_message("No cache found, nothing to promote", session_id)
        sys.exit(0)

    # Summarize session - get memories for this session and promote importance
    # For now, just write a summary note
    user_prompt = cache.get("user_prompt", "")
    if user_prompt:
        # Write summary
        summary_content = f"[session-end:{session_id}] Session summary: {user_prompt[:200]}"

        output, code = run_memory_hub([
            "write",
            summary_content,
            "--type", "summary",
            "--source", f"session:{session_id}",
            "--importance", "0.5"
        ])

        if code == 0:
            log_message(f"Session summary written for {session_id}", session_id)
        else:
            log_message(f"Error: {output}", session_id)

    # Clean up cache (optional - could keep for history)
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
