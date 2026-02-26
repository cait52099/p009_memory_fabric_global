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

## P008 Resolution Order

The install script locates P008 Memory Hub in this order:

1. **`MEMORY_FABRIC_P008_PATH`** environment variable (if set and directory exists) → `pip install -e`
2. **Relative path**: `../p008_memory_hub` (side-by-side clone) → `pip install -e`
3. **GitHub pip install**: `git+https://github.com/cait52099/p008_memory_hub.git`

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

## Episode Memory (Auto-Record + Smart Injection)

Episode Memory tracks task-level success/failure paths and can automatically inject relevant episodes into your prompts.

### Features

- **Auto-Record**: Automatically records episodes when sessions end (default: ON)
- **Smart Injection**: Only injects episodes when relevant (default: SMART mode)
- **Redaction**: Secrets are automatically redacted before storage (default: ON)

### Configuration

Configuration resolution order:
1. Environment variables
2. `~/.local/share/memory_fabric/config.json`
3. Defaults

| Flag | Default | Description |
|------|---------|-------------|
| `EPISODES_AUTO_RECORD` | `1` | Auto-record episodes on session end |
| `EPISODES_AUTO_INJECT` | `smart` | Auto-inject: `0` (off), `1` (always), `smart` (match-based) |
| `EPISODES_REDACT` | `1` | Redact secrets before storing episodes |
| `EPISODES_MAX_TOKENS` | `350` | Max tokens for episode injection |
| `EPISODES_MATCH_K` | `3` | Number of episodes to match |

### Smart Injection Policy

When `EPISODES_AUTO_INJECT=smart` (default), episodes are only injected when:
- Prompt contains keywords like `fix`, `bug`, `error`, `fail`, `exception`, `issue`, `problem`, `broken`
- OR session logs contain error signatures (`HTTP 401`, `fts5`, `false green`, etc.)

### Usage Examples

```bash
# Disable auto-record entirely
export EPISODES_AUTO_RECORD=0

# Always inject episodes (not just smart)
export EPISODES_AUTO_INJECT=1

# Disable auto-inject
export EPISODES_AUTO_INJECT=0

# Set custom config file
echo '{"EPISODES_AUTO_INJECT": "0"}' > ~/.local/share/memory_fabric/config.json
```

### Privacy

All episodes are automatically redacted before storage:
- API keys (`sk-*`, `Bearer tokens`, etc.)
- Emails
- Passwords
- Long hex strings (likely tokens)
- AWS/GitHub keys

### Recording Episodes Manually

```bash
memory-hub episode record --project myproject --intent "Fix login bug" --outcome success --step "Added validation" --json
```

### Retrieving Episodes

```bash
memory-hub episode match --project myproject --prompt "login bug" --k 5 --json
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
