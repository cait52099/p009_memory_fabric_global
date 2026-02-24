import { EventEmitter } from 'events';
import { spawn } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

interface HookConfig {
  contextDir: string;
  maxTokens: number;
  memoryHubPath: string;
}

const DEFAULT_CONFIG: HookConfig = {
  contextDir: '.memory_fabric',
  maxTokens: 1200,
  memoryHubPath: '/Users/caihongwei/.local/share/memory-fabric/bin/memory-hub'
};

export class MemoryFabricAutowire extends EventEmitter {
  private config: HookConfig;
  private workspace: string;

  constructor(workspace: string, config: Partial<HookConfig> = {}) {
    super();
    this.workspace = workspace;
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  async handleMessageReceived(prompt: string): Promise<void> {
    const contextDir = path.join(this.workspace, this.config.contextDir);
    const contextFile = path.join(contextDir, 'context_pack.md');

    // Ensure directory exists
    if (!fs.existsSync(contextDir)) {
      fs.mkdirSync(contextDir, { recursive: true });
    }

    // Call memory-hub assemble
    const result = await this.runMemoryHub(['assemble', prompt, '--max-tokens', String(this.config.maxTokens), '--json']);

    // Parse and write context
    try {
      const data = JSON.parse(result);
      const context = this.formatContext(data);
      fs.writeFileSync(contextFile, context, 'utf-8');
      console.log(`[memory-fabric] Wrote context to ${contextFile}`);
    } catch (e) {
      console.error('[memory-fabric] Failed to parse assemble output:', e);
    }
  }

  async handleAgentBootstrap(): Promise<void> {
    const toolsDir = path.join(this.workspace, this.config.contextDir);
    const toolsFile = path.join(toolsDir, 'TOOLS.md');

    if (!fs.existsSync(toolsDir)) {
      fs.mkdirSync(toolsDir, { recursive: true });
    }

    // Generate TOOLS.md with memory fabric commands
    const tools = this.generateToolsMd();
    fs.writeFileSync(toolsFile, tools, 'utf-8');
    console.log(`[memory-fabric] Created TOOLS.md at ${toolsFile}`);
  }

  async handleMessageSent(content: string): Promise<void> {
    // Write assistant output to session memory
    await this.runMemoryHub([
      'write',
      content,
      '--type', 'note',
      '--scope', 'session'
    ]);
    console.log('[memory-fabric] Wrote assistant output to session memory');
  }

  async handleCommandStop(): Promise<void> {
    // Summarize and promote to project
    await this.runMemoryHub(['summarize', '--type', 'note', '--promote']);
    console.log('[memory-fabric] Summarized and promoted session notes');
  }

  private formatContext(data: any): string {
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

  private generateToolsMd(): string {
    return `# Memory Fabric Tools

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
  }

  private runMemoryHub(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const proc = spawn(this.config.memoryHubPath, args, {
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
    });
  }
}

export default MemoryFabricAutowire;
