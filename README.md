# P009 Memory Fabric Global

A distributable, **global and invisible** integration that makes **Memory Fabric** the authoritative memory layer for Claude Code.

## What It Does (Globally)

- **Before every response**: automatically injects a `MEMORY_FABRIC_CONTEXT` context pack (from P008 Memory Hub) via Claude Code hooks
- **After every response**: writes back assistant output as session notes
- **Pre-compact**: re-injects key decisions so compaction doesn't lose them
- **Session end**: promotes session notes to project memory (summarize/promote)

## Prerequisites

- Claude Code installed and configured

## Installation Options

### Option 1: Clone both repos side-by-side (recommended)

```bash
# Clone both repos in the same parent directory
git clone https://github.com/cait52099/p008_memory_hub.git
git clone https://github.com/cait52099/p009_memory_fabric_global.git
cd p009_memory_fabric_global
bash scripts/install.sh
```

### Option 2: Set custom P008 path

```bash
# If P008 is in a different location, set environment variable
export MEMORY_FABRIC_P008_PATH=/path/to/p008_memory_hub
cd p009_memory_fabric_global
bash scripts/install.sh
```

### Option 3: Install P008 from GitHub

```bash
# If you don't have P008 locally, install.sh will install it from GitHub
cd p009_memory_fabric_global
bash scripts/install.sh
```

## Install (Global)

```bash
cd p009_memory_fabric_global
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
