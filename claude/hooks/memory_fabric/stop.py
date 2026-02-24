#!/usr/bin/env python3
from __future__ import annotations
# Stop hook - write assistant response back to Memory Fabric

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
    assistant_message = hook_input.get("last_assistant_message", "")

    project_id = get_project_id(cwd)
    log_message(f"Stop: project={project_id}, session={session_id}", session_id)

    # Read cached user prompt
    cache = read_cache(session_id)
    user_prompt = cache.get("user_prompt", "") if cache else ""

    if not user_prompt and not assistant_message:
        # Nothing to write
        sys.exit(0)

    # Write assistant response as a memory
    # Use first 500 chars of response
    content = assistant_message[:500] if assistant_message else user_prompt[:500]
    if content:
        # Write as a session note
        output, code = run_memory_hub([
            "write",
            f"[session:{session_id}] {content}",
            "--type", "note",
            "--source", f"session:{session_id}",
            "--importance", "0.3"
        ])

        if code == 0:
            log_message(f"Wrote session note for {session_id}", session_id)
        else:
            log_message(f"Error writing: {output}", session_id)

    # Exit without JSON output (side-effect only)
    sys.exit(0)


if __name__ == "__main__":
    main()
