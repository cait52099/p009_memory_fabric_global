# P009 Memory Fabric Global

A distributable, **global and invisible** integration that makes **Memory Fabric** the authoritative memory layer for Claude Code.

## What It Does (Globally)

- **Before every response**: automatically injects a `MEMORY_FABRIC_CONTEXT` context pack (from P008 Memory Hub) via Claude Code hooks
- **After every response**: writes back assistant output as session notes
- **Pre-compact**: re-injects key decisions so compaction doesn't lose them
- **Session end**: promotes session notes to project memory (summarize/promote)

## Prerequisites

- Claude Code installed and configured
- P008 Memory Hub exists at:
  `/Users/caihongwei/clawd/projects/p008_memory_hub`

## Install (Global)

```bash
cd /Users/caihongwei/clawd/projects/p009_memory_fabric_global
bash scripts/install.sh
```

## Run Doctor

Validate end-to-end:

```bash
bash scripts/doctor.sh
```

## Uninstall

Restore previous settings:

```bash
bash scripts/uninstall.sh
```

## Upgrade

Re-run install to update hooks:

```bash
bash scripts/install.sh
```

## Files

```
p009_memory_fabric_global/
├── claude/
│   ├── hooks/memory_fabric/   # Hook scripts (version controlled)
│   └── templates/hooks_block.json
├── scripts/
│   ├── install.sh    # Install/update hooks + runtime
│   ├── uninstall.sh  # Restore backup + remove hooks
│   └── doctor.sh     # Validate end-to-end
├── openclaw/        # Placeholder for OpenClaw integration
└── README.md
```
