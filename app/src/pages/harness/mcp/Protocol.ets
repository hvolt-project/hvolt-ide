// JSON-RPC 2.0 over MCP: request parsing, method dispatch, response shaping.
//
// Pure: no sockets, no UI, no globals besides the registry passed in. That is what lets the
// same functions serve a loopback client today and an external transport later.

import { ToolRegistry, ToolSpec } from './Registry';

export interface RpcError {
  code: number;
  message: string;
}

export interface RpcOutcome {
  /** JSON text ready to write back; '' means the message needed no reply (a notification). */
  body: string;
}

const PARSE_ERROR: number = -32700;
const INVALID_REQUEST: number = -32600;
const METHOD_NOT_FOUND: number = -32601;
const INVALID_PARAMS: number = -32602;
const INTERNAL_ERROR: number = -32603;

class Request {
  jsonrpc: string = '2.0';
  id: string = '';
  method: string = '';
  params: Record<string, Object> = {};
}

function response(id: string, result: Object): string {
  const envelope: Record<string, Object> = {
    'jsonrpc': '2.0',
    'id': id,
    'result': result
  };
  return JSON.stringify(envelope);
}

function failure(id: string, code: number, message: string): string {
  const error: RpcError = { code: code, message: message };
  const envelope: Record<string, Object> = {
    'jsonrpc': '2.0',
    'id': id,
    'error': error
  };
  return JSON.stringify(envelope);
}

function asRequest(text: string): Request | null {
  try {
    const parsed = JSON.parse(text) as Request;
    if (parsed === null || parsed.method === undefined || parsed.method.length === 0) {
      return null;
    }
    if (parsed.id === undefined) {
      parsed.id = '';
    }
    if (parsed.params === undefined) {
      parsed.params = {};
    }
    return parsed;
  } catch (e) {
    return null;
  }
}

/** `tools/call` arguments: MCP nests them under `arguments`. */
function callArguments(params: Record<string, Object>): Record<string, Object> {
  const nested = params['arguments'];
  if (nested === undefined || nested === null) {
    return {};
  }
  return nested as Record<string, Object>;
}

function toolName(params: Record<string, Object>): string {
  const name = params['name'];
  return name === undefined || name === null ? '' : name as string;
}

function textResult(text: string): Object {
  const block: Record<string, Object> = { 'type': 'text', 'text': text };
  const content: Object[] = [block];
  const result: Record<string, Object> = { 'content': content, 'isError': false };
  return result;
}

function errorResult(message: string): Object {
  const block: Record<string, Object> = { 'type': 'text', 'text': message };
  const content: Object[] = [block];
  const result: Record<string, Object> = { 'content': content, 'isError': true };
  return result;
}

async function dispatch(registry: ToolRegistry, request: Request): Promise<string> {
  switch (request.method) {
    case 'initialize': {
      const info: Record<string, Object> = {
        'protocolVersion': '2024-11-05',
        'capabilities': { 'tools': {} } as Record<string, Object>,
        'serverInfo': { 'name': 'hvolt-ide', 'version': '1.0.0' } as Record<string, Object>
      };
      return response(request.id, info);
    }
    case 'notifications/initialized':
      return '';
    case 'tools/list': {
      const reply: Record<string, Object> = { 'tools': registry.descriptors() };
      return response(request.id, reply);
    }
    case 'tools/call': {
      const name = toolName(request.params);
      const spec: ToolSpec | undefined = registry.get(name);
      if (spec === undefined) {
        return response(request.id, errorResult('unknown tool: ' + name));
      }
      try {
        const text = await spec.handler(callArguments(request.params));
        return response(request.id, textResult(text));
      } catch (e) {
        return response(request.id, errorResult((e as Error).message));
      }
    }
    default:
      return failure(request.id, METHOD_NOT_FOUND, 'unknown method: ' + request.method);
  }
}

/** One request in, one JSON text out. `''` for messages that need no reply. */
export async function handleMessage(registry: ToolRegistry, text: string): Promise<RpcOutcome> {
  const request = asRequest(text);
  if (request === null) {
    const outcome: RpcOutcome = { body: failure('', PARSE_ERROR, 'malformed JSON-RPC request') };
    return outcome;
  }
  const outcome: RpcOutcome = { body: await dispatch(registry, request) };
  return outcome;
}

/** Exposed for the tests that pin the error codes. */
export const RPC_ERRORS: number[] = [PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS,
  INTERNAL_ERROR];
