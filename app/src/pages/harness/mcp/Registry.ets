// The tool table. One place lists what the IDE exposes; the MCP layer, the built-in loop and
// any future transport all read from it rather than switching on tool names.
//
// A tool is a pure description plus a handler. Approval is a property of the table, not of the
// call site, so the same rule applies whether the caller is the model or an external client.

export type ApprovalLevel = 'none' | 'confirm';

/**
 * A tool either states its approval once, or decides per call from the arguments. The dispatcher
 * resolves it before the handler runs, so a tool cannot skip the gate by not calling it itself.
 * This is structurally the same type `loop/Dispatch.ts` declares; the two files stay independent so
 * the dispatcher keeps compiling without ArkTS imports.
 */
export type ApprovalRule = ApprovalLevel | ((args: Record<string, Object>) => ApprovalLevel);

export interface ToolSpec {
  name: string;
  description: string;
  /** JSON Schema for the arguments object; passed through to MCP clients verbatim. */
  inputSchema: Record<string, Object>;
  approval: ApprovalRule;
  /** Runs on the UI thread: handlers must not block (device calls go through the worker). */
  handler: (args: Record<string, Object>) => Promise<string>;
}

export class ToolRegistry {
  private tools: Map<string, ToolSpec> = new Map();

  register(spec: ToolSpec): void {
    if (spec.name.length === 0) {
      throw new Error('tool name must not be empty');
    }
    if (this.tools.has(spec.name)) {
      throw new Error('tool already registered: ' + spec.name);
    }
    this.tools.set(spec.name, spec);
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  get(name: string): ToolSpec | undefined {
    return this.tools.get(name);
  }

  /** Registration order is the order clients see; stable output makes diffs readable. */
  list(): ToolSpec[] {
    const out: ToolSpec[] = [];
    this.tools.forEach((spec: ToolSpec) => {
      out.push(spec);
    });
    return out;
  }

  /** Tools as MCP reports them: name, description, schema. */
  descriptors(): Record<string, Object>[] {
    const out: Record<string, Object>[] = [];
    for (const spec of this.list()) {
      const entry: Record<string, Object> = {
        'name': spec.name,
        'description': spec.description,
        'inputSchema': spec.inputSchema
      };
      out.push(entry);
    }
    return out;
  }
}

/** The process-wide table. Tools are registered once at startup, from a single place. */
export const TOOLS: ToolRegistry = new ToolRegistry();
