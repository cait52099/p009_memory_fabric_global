# Memory Fabric Autowire Hook

Injects Memory Fabric context into OpenClaw agent sessions.

## Events Handled

### message:received
When a message is received, assemble context and write to workspace:
- Calls `memory-hub assemble <prompt> --json`
- Writes result to `workspace/.memory_fabric/context_pack.md`
- Claude Code reads this file for context

### agent:bootstrap
When agent bootstraps:
- Creates `workspace/.memory_fabric/TOOLS.md` with memory fabric tools
- Injects into bootstrapFiles for agent awareness

### message:sent
After assistant responds:
- Calls `memory-hub write` with assistant output
- Scope: session, tracks conversation history

### command:stop
When agent stops:
- Summarizes session notes
- Promotes to project-level memory

## Configuration

- `MEMORY_FABRIC_CONTEXT_DIR`: Where to store context files (default: `.memory_fabric`)
- `MEMORY_FABRIC_MAX_TOKENS`: Max tokens for context assembly (default: 1200)

## Dependencies

- `memory-hub` CLI at `~/.local/share/memory-fabric/bin/memory-hub`
- OpenClaw hook pack system
