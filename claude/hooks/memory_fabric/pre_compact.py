#!/usr/bin/env python3
from __future__ import annotations
# PreCompact hook - re-inject key decisions before memory compaction

import json
import sys
import os

# Add hooks dir to path
sys.path.insert(0, os.path.dirname(__file__))

from _util import (
    get_project_id,
    get_session_id,
    run_memory_hub,
    read_hook_input,
    log_message
)


def main():
    hook_input = read_hook_input()

    cwd = hook_input.get("cwd", os.getcwd())
    session_id = get_session_id(hook_input)

    project_id = get_project_id(cwd)
    log_message(f"PreCompact: project={project_id}", session_id)

    # Query for key decisions and constraints
    query = "important decisions constraints architecture design"
    output, code = run_memory_hub([
        "assemble",
        query,
        "--max-tokens", "800",
        "--type", "decision",
        "--json"
    ])

    if code != 0:
        log_message(f"Error: {output}", session_id)
        sys.exit(0)

    try:
        result = json.loads(output)
    except json.JSONDecodeError:
        log_message(f"Failed to parse JSON: {output}", session_id)
        sys.exit(0)

    # Build context from result
    context_parts = []
    context_parts.append("<!-- MEMORY_FABRIC_PRECOMPACT -->")
    context_parts.append("## Key Decisions (refreshed)")

    memories = result.get("memories", [])
    if memories:
        for mem in memories[:5]:
            content = mem.get("content", "")[:200]
            context_parts.append(f"- {content}")
    else:
        context_parts.append("(No key decisions found)")

    context_parts.append("<!-- END_MEMORY_FABRIC_PRECOMPACT -->")

    context = "\n".join(context_parts)

    # Output JSON for hook
    output_json = {
        "hookSpecificOutput": {
            "hookEventName": "PreCompact",
            "additionalContext": context
        }
    }

    print(json.dumps(output_json))
    log_message(f"PreCompact context injected", session_id)


if __name__ == "__main__":
    main()
