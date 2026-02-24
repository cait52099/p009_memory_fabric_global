#!/usr/bin/env python3
from __future__ import annotations
# UserPromptSubmit hook - inject Memory Fabric context before Claude responds

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
    write_cache,
    log_message
)


def main():
    hook_input = read_hook_input()

    cwd = hook_input.get("cwd", os.getcwd())
    session_id = get_session_id(hook_input)
    user_prompt = hook_input.get("userPrompt") or hook_input.get("prompt") or ""

    if not user_prompt:
        # No prompt to process
        sys.exit(0)

    project_id = get_project_id(cwd)
    log_message(f"UserPromptSubmit: project={project_id}, session={session_id}", session_id)

    # Cache the prompt for later write-back
    write_cache(session_id, {
        "user_prompt": user_prompt,
        "project_id": project_id,
        "cwd": cwd
    })

    # Assemble context from memory hub
    # Query with the prompt, limited tokens
    output, code = run_memory_hub([
        "assemble",
        user_prompt,
        "--max-tokens", "1200",
        "--json"
    ])

    if code != 0:
        log_message(f"Error assembling context: {output}", session_id)
        sys.exit(0)

    try:
        result = json.loads(output)
    except json.JSONDecodeError:
        log_message(f"Failed to parse JSON: {output}", session_id)
        sys.exit(0)

    # Build context from result
    context_parts = []
    context_parts.append("<!-- MEMORY_FABRIC_CONTEXT -->")

    # Add memories
    memories = result.get("memories", [])
    if memories:
        context_parts.append("## Relevant Memories")
        for mem in memories[:5]:  # Limit to top 5
            content = mem.get("content", "")[:200]
            mtype = mem.get("type", "general")
            context_parts.append(f"- [{mtype}] {content}")

    # Add summaries
    summaries = result.get("summaries", [])
    if summaries:
        context_parts.append("## Summaries")
        for s in summaries[:3]:
            content = s.get("content", "")[:150]
            context_parts.append(f"- {content}")

    if not memories and not summaries:
        context_parts.append("(No relevant memories found)")

    context_parts.append("<!-- END_MEMORY_FABRIC_CONTEXT -->")

    context = "\n".join(context_parts)

    # Output JSON for hook
    output_json = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context
        }
    }

    print(json.dumps(output_json))
    log_message(f"Injected context ({len(context)} chars)", session_id)


if __name__ == "__main__":
    main()
