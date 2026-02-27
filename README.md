# P009 Memory Fabric Global

A distributable, **global and invisible** integration that makes **Memory Fabric** the authoritative memory layer for Claude Code and OpenClaw.

## Why It Matters

- **Continuity**: Your AI remembers what you worked on last week, not just this session
- **Context injection**: Relevant memories automatically appear before every response
- **Episode tracking**: Records task intents and outcomes so the system learns from success/failure patterns

## Quickstart (Claude Code)

```bash
# 1. Install
git clone https://github.com/cait52099/p009_memory_fabric_global.git
cd p009_memory_fabric_global
bash scripts/install.sh

# 2. Validate
bash scripts/doctor.sh

# 3. Use - it works automatically
# Just start using Claude Code - memories are injected before every response
```

## Quickstart (OpenClaw)

```bash
# 1. Install OpenClaw gateway
npm install -g @anthropic-ai/openclaw
openclaw install

# 2. Install the episode sync hook pack
bash scripts/install_openclaw.sh

# 3. Use - episodes auto-record at session end
claude --agent main
```

## How It Learns

- **Best Known Path**: Semantic episode matching finds similar past tasks and injects their context
- **Pitfalls**: Error signatures (401, 403, timeout) trigger episode injection to avoid repeated mistakes

## Privacy & Redaction

All free-text fields are redacted before storage:
- API keys (`sk-...`)
- Tokens (`ghp_...`, `gho_...`)
- Email addresses
- AWS keys (`AKIA...`)

Episode records use deterministic P008 redaction - nothing sensitive leaves your machine.

---

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
- **Smart Injection**: Injects episodes when relevant (default: SMART mode)
  - SMART = (episode match by intent fingerprint) OR (error signature reflex)
  - Signatures: `http 401`, `http 403`, `fts5`, `false green`, `authentication failed`, etc.
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

#### Custom Signature Reflex List

You can customize the error signatures that trigger injection by adding to config:

```json
{
  "episodes": {
    "signatureReflex": [
      "HTTP 401",
      "fts5: syntax error",
      "false green",
      "gateway timeout"
    ]
  }
}
```

Save to: `~/.local/share/memory-fabric/config.json`

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

## OpenClaw Integration

Memory Fabric integrates with OpenClaw via the `memory-fabric-autowire` hook pack.

### Installation

```bash
cd p009_memory_fabric_global
bash scripts/install_openclaw.sh
```

### Configuration

The OpenClaw handler supports episode configuration via the hook config:

```json
{
  "hooks": {
    "internal": {
      "entries": {
        "memory-fabric-autowire": {
          "enabled": true,
          "contextDir": ".memory_fabric",
          "maxTokens": 1200,
          "episodesAutoRecord": true,
          "episodesAutoInject": "smart",
          "episodesRedact": true,
          "episodesMaxTokens": 350
        }
      }
    }
  }
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `episodesAutoRecord` | `true` | Auto-record episodes when sessions end |
| `episodesAutoInject` | `smart` | Smart inject episodes: `0` (off), `1` (always), `smart` (match-based) |
| `episodesRedact` | `true` | Redact secrets before storing episodes |
| `episodesMaxTokens` | `350` | Max tokens for episode injection |

### Smart Injection

When `episodesAutoInject` is set to `smart` (default), episodes are automatically injected into context when:
- **Episode match**: Semantic similarity to past episodes (using `memory-hub episode match`)
- **Error signatures**: Prompt contains error patterns like `401`, `403`, `timeout`, `connection refused`, `not found`, `permission denied`

### Redaction

All episode content is automatically redacted before storage:
- API keys (`sk-*`, `Bearer tokens`)
- Email addresses
- Passwords
- Long hex strings (likely tokens)
- AWS/GitHub keys

### Doctor Script

Validate the OpenClaw integration:

```bash
bash scripts/doctor_openclaw.sh
```

This script:
1. Verifies hook is installed and enabled
2. Validates episode configuration
3. Attempts E2E trigger (if gateway running)
4. Checks for context_pack.md and TOOLS.md artifacts
5. Tests SMART injection (match-based yes/no)

### Troubleshooting

**Gateway not running**
```bash
# Check gateway status
openclaw gateway status

# Start gateway
openclaw gateway start
```

**Workspace directory mismatch**
- The hook uses workspace from `agents.defaults.workspace` in openclaw.json
- If artifacts are missing, check: `openclaw config get agents.defaults.workspace`
- Ensure the workspace directory exists and is writable

**Artifacts not created**
1. Check hook is enabled: `openclaw hooks list`
2. Check hook is ready: `openclaw hooks info memory-fabric-autowire`
3. Check config: `openclaw config get hooks.internal.entries.memory-fabric-autowire`
4. Check hook logs in workspace: `cat ~/.memory_fabric/hook.log`

**Episode injection not working**
- Ensure `episodesAutoInject` is set to `smart` (default)
- Check that episodes exist: `memory-hub episode list --project yourproject`
- SMART injection triggers on semantic match OR error signatures (401, 403, timeout)

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
