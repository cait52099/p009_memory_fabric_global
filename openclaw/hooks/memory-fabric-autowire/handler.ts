import { spawn } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const HOOK_KEY = "memory-fabric-autowire";

const DEFAULT_CONFIG = {
  contextDir: '.memory_fabric',
  maxTokens: 1200,
  memoryHubPath: '/Users/caihongwei/.local/share/memory-fabric/bin/memory-hub'
};

// Event type guards
function isMessageReceivedEvent(event: any): boolean {
  return event?.type === 'message' && event?.action === 'received';
}

function isAgentBootstrapEvent(event: any): boolean {
  return event?.type === 'agent' && event?.action === 'bootstrap';
}

function isMessageSentEvent(event: any): boolean {
  return event?.type === 'message' && event?.action === 'sent';
}

function isCommandStopEvent(event: any): boolean {
  return event?.type === 'command' && event?.action === 'stop';
}

// Resolve hook config from entry
function resolveHookConfig(cfg: any, hookKey: string): any {
  return cfg?.hooks?.internal?.entries?.[hookKey] || {};
}

// Logging
function log(message: string): void {
  console.log(`[memory-fabric-autowire] ${message}`);
}

function logError(message: string, err?: any): void {
  console.error(`[memory-fabric-autowire] ERROR: ${message}`, err || '');
}

// Main hook handler
async function memoryFabricHook(event: any): Promise<void> {
  const context = event?.context;
  if (!context) {
    logError('No context in event');
    return;
  }

  const workspaceDir = context.workspaceDir;
  if (!workspaceDir) {
    logError('No workspaceDir in context');
    return;
  }

  const hookConfig = resolveHookConfig(context.cfg, HOOK_KEY);
  if (hookConfig?.enabled === false) {
    log('Hook disabled, skipping');
    return;
  }

  const config = { ...DEFAULT_CONFIG, ...hookConfig };
  const contextDir = path.join(workspaceDir, config.contextDir);

  // Ensure context directory exists
  if (!fs.existsSync(contextDir)) {
    fs.mkdirSync(contextDir, { recursive: true });
  }

  // Add hook.log for debugging
  const logFile = path.join(contextDir, 'hook.log');

  function appendLog(msg: string): void {
    const timestamp = new Date().toISOString();
    fs.appendFileSync(logFile, `[${timestamp}] ${msg}\n`);
  }

  appendLog(`Event: ${event.type}:${event.action}, workspace: ${workspaceDir}`);

  try {
    if (isAgentBootstrapEvent(event)) {
      // Handle agent:bootstrap - create TOOLS.md
      appendLog('Handling agent:bootstrap');
      await handleAgentBootstrap(context, contextDir, config, appendLog);
    } else if (isMessageReceivedEvent(event)) {
      // Handle message:received - assemble context
      appendLog('Handling message:received');
      await handleMessageReceived(context, contextDir, config, appendLog);
    } else if (isMessageSentEvent(event)) {
      // Handle message:sent - write assistant output
      appendLog('Handling message:sent');
      await handleMessageSent(context, config, appendLog);
    } else if (isCommandStopEvent(event)) {
      // Handle command:stop - summarize
      appendLog('Handling command:stop');
      await handleCommandStop(config, appendLog);
    } else {
      appendLog(`Unhandled event: ${event.type}:${event.action}`);
    }
  } catch (err: any) {
    appendLog(`Error: ${err.message}`);
    logError(`Handler error: ${err.message}`, err);
  }
}

async function handleAgentBootstrap(context: any, contextDir: string, config: any, appendLog: (msg: string) => void): Promise<void> {
  const toolsFile = path.join(contextDir, 'TOOLS.md');
  const contextFile = path.join(contextDir, 'context_pack.md');

  const tools = `# Memory Fabric Tools

Available commands for managing memory:

\`\`\`bash
# Search memories
memory-hub search "query"

# Write a memory
memory-hub write "content" --type note

# Assemble context for current task
memory-hub assemble "what I'm working on" --max-tokens 1200

# Summarize session
memory-hub summarize --type note
\`\`\`

See \`memory-hub --help\` for full command list.
`;

  fs.writeFileSync(toolsFile, tools, 'utf-8');
  appendLog(`Created TOOLS.md at ${toolsFile}`);
  log(`Created TOOLS.md at ${toolsFile}`);

  // Also create context_pack.md during bootstrap (pre-assemble context)
  const agentId = context.agentId || 'agent';
  try {
    appendLog(`Assembling bootstrap context for ${agentId}...`);
    const result = await runMemoryHub([
      'assemble',
      `agent ${agentId} starting`,
      '--max-tokens', String(config.maxTokens),
      '--json'
    ], appendLog);

    const data = JSON.parse(result.trim());
    const context_md = formatContext(data);
    fs.writeFileSync(contextFile, context_md, 'utf-8');
    appendLog(`Created context_pack.md at ${contextFile}`);
    log(`Created context_pack.md at ${contextFile}`);
  } catch (err: any) {
    appendLog(`Failed to create context_pack.md: ${err.message}`);
    logError(`Failed to create context_pack.md: ${err.message}`, err);
  }

  // Inject into bootstrapFiles
  if (context.bootstrapFiles) {
    context.bootstrapFiles.push({
      name: 'memory-fabric-tools',
      path: toolsFile
    });
    appendLog(`Injected TOOLS.md into bootstrapFiles`);
  }
}

async function handleMessageReceived(context: any, contextDir: string, config: any, appendLog: (msg: string) => void): Promise<void> {
  const content = context.content;
  if (!content) {
    appendLog('No content in message event');
    return;
  }

  const contextFile = path.join(contextDir, 'context_pack.md');

  // Call memory-hub assemble
  appendLog(`Assembling context for: ${content.slice(0, 50)}...`);

  try {
    const result = await runMemoryHub([
      'assemble',
      content,
      '--max-tokens', String(config.maxTokens),
      '--json'
    ], appendLog);

    const data = JSON.parse(result.trim());
    const context_md = formatContext(data);

    fs.writeFileSync(contextFile, context_md, 'utf-8');
    appendLog(`Wrote context to ${contextFile}`);
    log(`Wrote context to ${contextFile}`);
  } catch (err: any) {
    appendLog(`Failed to assemble context: ${err.message}`);
    logError(`Failed to assemble context: ${err.message}`, err);
  }
}

async function handleMessageSent(context: any, config: any, appendLog: (msg: string) => void): Promise<void> {
  const content = context.content;
  if (!content) {
    return;
  }

  appendLog(`Writing message to memory: ${content.slice(0, 30)}...`);

  try {
    await runMemoryHub([
      'write',
      content,
      '--type', 'note',
      '--scope', 'session'
    ], appendLog);
    appendLog('Wrote message to session memory');
  } catch (err: any) {
    appendLog(`Failed to write: ${err.message}`);
  }
}

async function handleCommandStop(config: any, appendLog: (msg: string) => void): Promise<void> {
  appendLog('Summarizing session...');

  try {
    await runMemoryHub([
      'summarize',
      '--type', 'note',
      '--promote'
    ], appendLog);
    appendLog('Summarized and promoted session notes');
  } catch (err: any) {
    appendLog(`Failed to summarize: ${err.message}`);
  }
}

function formatContext(data: any): string {
  let md = '<!-- MEMORY_FABRIC_CONTEXT -->\n\n';

  if (data.memories?.length) {
    md += '## Relevant Memories\n\n';
    for (const mem of data.memories.slice(0, 5)) {
      const content = mem.content?.slice(0, 200) || '';
      const mtype = mem.type || 'general';
      md += `- [${mtype}] ${content}\n`;
    }
    md += '\n';
  }

  if (data.summaries?.length) {
    md += '## Summaries\n\n';
    for (const s of data.summaries.slice(0, 3)) {
      const content = s.content?.slice(0, 150) || '';
      md += `- ${content}\n`;
    }
    md += '\n';
  }

  md += '<!-- END_MEMORY_FABRIC_CONTEXT -->';
  return md;
}

function runMemoryHub(args: string[], appendLog: (msg: string) => void): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn(DEFAULT_CONFIG.memoryHubPath, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });

    proc.on('close', (code) => {
      if (code === 0) {
        resolve(stdout);
      } else {
        reject(new Error(`memory-hub exited ${code}: ${stderr}`));
      }
    });

    proc.on('error', (err) => {
      reject(err);
    });
  });
}

export default memoryFabricHook;
