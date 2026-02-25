#!/usr/bin/env python3
from __future__ import annotations
# UserPromptSubmit hook - inject Memory Fabric context before Claude responds

import json
import subprocess
import sys
import os
from datetime import datetime

# Add hooks dir to path
sys.path.insert(0, os.path.dirname(__file__))

from _util import (
    get_project_id,
    extract_project_from_prompt,
    get_session_id,
    run_memory_hub,
    read_hook_input,
    write_cache,
    log_message
)

# Max recent projects to show
MAX_RECENT_PROJECTS = 8


def fetch_recent_projects() -> list:
    """Fetch recent project snapshots from global registry."""
    # Search for project_registry entries using --project filter for exact source match
    output, code = run_memory_hub([
        "search",
        "project_snapshot",
        "--top-k", "50",  # Fetch more to ensure we get newest
        "--project", "global:project_registry",
        "--json"
    ])

    if code != 0 or not output.strip():
        return []

    try:
        results = json.loads(output.strip())
    except json.JSONDecodeError:
        return []

    # Parse results - format is "project_id | git_url | timestamp | summary"
    # Use raw content as sort key to get truly latest (includes token number)
    projects = []
    for r in results:
        content = r.get("content", "")
        # Parse: "p009_memory_fabric_global | https://github.com/... | 2026-02-26T... | summary"
        parts = content.split(" | ")
        if len(parts) >= 1:
            project_id = parts[0].strip()
            git_url = parts[1].strip() if len(parts) > 1 else ""
            timestamp = parts[2].strip() if len(parts) > 2 else ""
            summary = parts[3].strip() if len(parts) > 3 else ""
            projects.append({
                "project_id": project_id,
                "git_url": git_url,
                "timestamp": timestamp,
                "summary": summary,
                "raw": content  # Use full content for sorting
            })

    # Sort by full content ascending (so newest is last)
    projects.sort(key=lambda x: x.get("raw", ""))

    # Deduplicate by project_id - keep the LATEST (iterate reversed to get newest)
    seen = {}
    unique = []
    for p in reversed(projects):  # Iterate newest to oldest
        pid = p["project_id"]
        if pid and pid not in seen:
            seen[pid] = True
            unique.append(p)  # Keep first occurrence (newest)

    # Reverse back to get correct order (newest first)
    unique.reverse()

    return unique[:MAX_RECENT_PROJECTS]


def format_recent_projects_block(projects: list) -> str:
    """Format recent projects into a compact markdown block."""
    if not projects:
        return ""

    lines = ["## Recent Projects"]
    for p in projects:
        pid = p.get("project_id", "?")
        summary = p.get("summary", "")
        if summary:
            # Truncate summary to ~30 chars
            summary = summary[:40] + "..." if len(summary) > 40 else summary
            lines.append(f"- {pid} — {summary}")
        else:
            lines.append(f"- {pid}")

    return "\n".join(lines)


def main():
    hook_input = read_hook_input()

    cwd = hook_input.get("cwd", os.getcwd())
    session_id = get_session_id(hook_input)
    user_prompt = hook_input.get("userPrompt") or hook_input.get("prompt") or ""

    if not user_prompt:
        # No prompt to process
        sys.exit(0)

    # Project Resolver: Check if prompt mentions a known project
    project_override = extract_project_from_prompt(user_prompt)

    # Use override if found, otherwise use cwd-based detection
    if project_override:
        project_id = project_override
        log_message(f"UserPromptSubmit: project={project_id} (override), session={session_id}", session_id)
    else:
        project_id = get_project_id(cwd)
        log_message(f"UserPromptSubmit: project={project_id}, session={session_id}", session_id)

    # Cache the prompt for later write-back
    write_cache(session_id, {
        "user_prompt": user_prompt,
        "project_id": project_id,
        "cwd": cwd
    })

    # ALWAYS fetch recent projects for the global registry snippet
    recent_projects = fetch_recent_projects()
    recent_block = format_recent_projects_block(recent_projects)

    # Build memory-hub assemble command for project-specific context
    cmd = [
        "assemble",
        user_prompt,
        "--max-tokens", "1200",
        "--json"
    ]

    # If project override detected, add project filter to retrieval
    if project_override:
        cmd.extend(["--project", project_id])

    # Optional: Add episode context if enabled
    episodes_enabled = os.environ.get("MEMORY_FABRIC_EPISODES", "0") == "1"
    episode_context = ""
    if episodes_enabled and project_id:
        episode_cmd = cmd.copy()
        episode_cmd.append("--with-episodes")
        ep_output, ep_code = run_memory_hub(episode_cmd)
        if ep_code == 0:
            try:
                ep_result = json.loads(ep_output.strip())
                episode_context = ep_result.get("content", "")
            except json.JSONDecodeError:
                pass

    output, code = run_memory_hub(cmd)

    if code != 0:
        log_message(f"Error assembling context: {output}", session_id)
        sys.exit(0)

    try:
        # memory-hub may output leading whitespace, strip it
        result = json.loads(output.strip())
    except json.JSONDecodeError:
        log_message(f"Failed to parse JSON: {output}", session_id)
        sys.exit(0)

    # Build context from result
    context_parts = []
    context_parts.append("<!-- MEMORY_FABRIC_CONTEXT -->")

    # ALWAYS inject Recent Projects block first (global registry)
    if recent_block:
        context_parts.append(f"<!-- GLOBAL_PROJECT_REGISTRY -->")
        context_parts.append(recent_block)
        context_parts.append("<!-- END_GLOBAL_PROJECT_REGISTRY -->")

    # Add project override marker if applicable
    if project_override:
        context_parts.append(f"<!-- PROJECT_OVERRIDE: {project_id} -->")

    # Add episode context if enabled (behind MEMORY_FABRIC_EPISODES=1)
    if episode_context:
        context_parts.append("<!-- EPISODE_CONTEXT -->")
        context_parts.append(episode_context)
        context_parts.append("<!-- END_EPISODE_CONTEXT -->")

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
    log_message(f"Injected context ({len(context)} chars), recent_projects={len(recent_projects)}", session_id)


if __name__ == "__main__":
    main()
