// Background jobs: a command that outlives one tool call.
//
// A build on this device takes tens of seconds and an install can take longer. A tool call that
// returns only when the command exits holds the turn open for that whole time, and a turn that
// times out loses the output. So a job is started and named, and its output is read separately —
// the model can keep reasoning, or read the tail while the command is still running.

import { hvoltAsync } from '../../model/Connect';
import { FILES } from '../../model/Stage';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

interface Job {
  id: string;
  argv: string[];
  cwd: string;
  output: string;
  /** -1 while running; the command's exit code once it finishes. */
  code: number;
  startedAt: number;
}

const MAX_JOBS = 8;
const MAX_OUTPUT = 400000;

const JOBS: Map<string, Job> = new Map<string, Job>();
let nextJob = 1;

function registry(): Map<string, Job> {
  return JOBS;
}

function start(argv: string[], cwd: string): Job {
  const job: Job = {
    id: 'job' + nextJob,
    argv: argv,
    cwd: cwd,
    output: '',
    code: -1,
    startedAt: Date.now()
  };
  nextJob += 1;
  registry().set(job.id, job);
  hvoltAsync(argv, cwd, FILES, (raw: string) => {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const codeValue = parsed['code'];
      const outputValue = parsed['output'];
      job.code = codeValue === undefined ? -1 : codeValue as number;
      job.output = outputValue === undefined ? raw : outputValue as string;
    } catch (e) {
      // 回调只在命令结束时进来一次。走到这里说明进程已经退出，只是输出不是约定的 JSON
      // （构建失败时 hvolt 打的是错误文本）。这里再写 -1 就等于「还在跑」，job 会永久卡在
      // running；标成失败，让 job_output 能收口。
      job.code = 1;
      job.output = raw.substring(0, 2000);
    }
    if (job.output.length > MAX_OUTPUT) {
      job.output = job.output.substring(job.output.length - MAX_OUTPUT);
    }
  });
  return job;
}

function describe(job: Job): string {
  const state = job.code === -1 ? 'running' : 'exit ' + job.code;
  return job.id + ' [' + state + '] ' + job.argv.join(' ');
}

export function registerJobTools(registryTable: ToolRegistry, ctx: FileContext): void {
  registryTable.register({
    name: 'job_start',
    description: 'Start a toolchain command in the background and return its job id at once. Use '
      + 'it for anything that can take longer than a tool call: build, sign, push, install. Read '
      + 'progress with job_output; the command keeps running while the turn continues.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The hvolt subcommand and its arguments, e.g. "build" or "push --hap x.hap".'
        },
        'cwd': {
          'type': 'string',
          'description': 'Working directory; defaults to the open project.'
        }
      },
      'required': ['command']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const line = (args['command'] as string).trim();
      if (line.length === 0) {
        return Promise.resolve('error: command is required');
      }
      const parts: string[] = [];
      for (const word of line.split(' ')) {
        if (word.length > 0) {
          parts.push(word);
        }
      }
      const cwdArg = args['cwd'];
      const project = ctx.projectDir();
      const cwd = cwdArg === undefined ? project : (cwdArg as string);
      if (registry().size >= MAX_JOBS) {
        return Promise.resolve('error: too many jobs; wait for one to finish');
      }
      const job = start(parts, cwd);
      return Promise.resolve('started ' + job.id + ' ' + parts.join(' '));
    }
  });

  registryTable.register({
    name: 'job_output',
    description: 'Read a running or finished job: its exit code when done and the newest output. '
      + 'Pass offset to get only what was appended since that many characters.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': { 'type': 'string', 'description': 'Job id returned by job_start.' },
        'offset': { 'type': 'number', 'description': 'Character offset already read.' },
        'tail': { 'type': 'number', 'description': 'How many trailing lines to return; default 40.' }
      },
      'required': ['id']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const id = args['id'] as string;
      const job = registry().get(id);
      if (job === undefined) {
        return Promise.resolve('error: no such job: ' + id);
      }
      const offsetArg = args['offset'];
      const offset = offsetArg === undefined ? 0 : offsetArg as number;
      const body = offset > 0 && offset < job.output.length
        ? job.output.substring(offset) : job.output;
      const tailArg = args['tail'];
      const tail = tailArg === undefined ? 40 : tailArg as number;
      const lines: string[] = body.split('\n');
      const start = lines.length > tail ? lines.length - tail : 0;
      const head = job.code === -1 ? 'running' : 'exit ' + job.code;
      return Promise.resolve(head + ' at ' + job.output.length + ' chars\n' +
        lines.slice(start).join('\n'));
    }
  });

  registryTable.register({
    name: 'job_list',
    description: 'List the background jobs of this session with their state.',
    inputSchema: { 'type': 'object', 'properties': {}, 'required': [] },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      if (registry().size === 0) {
        return Promise.resolve('no jobs');
      }
      const lines: string[] = [];
      registry().forEach((job: Job) => {
        lines.push(describe(job));
      });
      return Promise.resolve(lines.join('\n'));
    }
  });
}