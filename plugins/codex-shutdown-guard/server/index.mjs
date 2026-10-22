#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { dirname, resolve, win32 } from 'node:path';
import { fileURLToPath } from 'node:url';

const BRIDGE = resolve(dirname(fileURLToPath(import.meta.url)), '../skills/codex-shutdown-guard/scripts/Invoke-Guard.ps1');
const SUPPORTED_PROTOCOLS = new Set(['2025-06-18', '2025-03-26', '2024-11-05']);
const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_INPUT_BYTES = 1024 * 1024;
const ACTION_TIMEOUT_MS = 30_000;

const emptyInput = { type: 'object', properties: {}, additionalProperties: false };
const definitions = [
  ['guard_status', 'Inspect', 'Read native guard status, settings, task snapshot and diagnostics without launching or changing the guard.', true, false, true],
  ['guard_show', 'Show', 'Request the original native guard panel. The panel retains default styling, hide/drag behavior, task management and per-task ignore controls. A queued request is not confirmation the panel is visible.', false, false, false],
  ['guard_arm', 'Arm', 'Request automatic PC shutdown after monitored tasks finish and the native countdown completes. This can really shut down Windows. A queued request is not confirmation that arming or shutdown has completed.', false, true, false],
  ['guard_disarm', 'Disarm', 'Request cancellation of automatic shutdown and the native guard countdown. Check guard_status afterward; a queued request is not confirmation it has been processed.', false, false, true],
  ['guard_rescan', 'Rescan', 'Queue a fresh native task scan. The guard processes the request asynchronously; read guard_status afterward for the resulting snapshot.', false, false, false],
  ['guard_stop', 'Stop', 'Request the native guard to cancel its shutdown monitoring and exit. This stops the guard, not the PC. A queued request is not confirmation the process has exited.', false, false, true],
  ['guard_launch_codex', 'LaunchCodex', 'Launch Codex using the existing guard launcher/proxy behavior. Reported launch submission does not prove the Codex window is ready.', false, false, false],
  ['guard_set_codex_autostart', 'SetAutoStartCodex', 'Set whether starting the native guard also starts Codex. This is the original guard setting, not Windows login startup. The bridge reports whether a running tray restart is needed.', false, false, true],
  ['guard_set_guard_autostart', 'SetAutoStartGuard', 'Set whether opening Codex starts the native guard unarmed. Enabling saves a separate setting, installs a per-user Windows startup shortcut and starts the local Codex startup watcher. This does not arm automatic shutdown.', false, false, true],
];
const booleanActions = new Set(['SetAutoStartCodex', 'SetAutoStartGuard']);
const tools = definitions.map(([name, , description, readOnlyHint, destructiveHint, idempotentHint]) => ({
  name,
  description,
  inputSchema: name.endsWith('_autostart')
    ? { type: 'object', properties: { enabled: { type: 'boolean', description: name === 'guard_set_guard_autostart' ? 'Whether opening Codex starts the guard unarmed.' : 'Whether to start Codex when the guard starts.' } }, required: ['enabled'], additionalProperties: false }
    : emptyInput,
  annotations: { readOnlyHint, destructiveHint, idempotentHint, openWorldHint: false },
}));
const actionByTool = new Map(definitions.map(([name, action]) => [name, action]));

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

class RpcError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function exactKeys(value, allowed, label) {
  if (!isObject(value) || Object.keys(value).some(key => !allowed.includes(key))) {
    throw new RpcError(-32602, `${label} must be an object with only: ${allowed.join(', ') || '(no properties)'}.`);
  }
}

function bridgeErrorMessage(stdout, stderr, fallback) {
  try {
    const value = JSON.parse(stdout);
    if (isObject(value)) {
      const message = typeof value.error === 'string' ? value.error : value.error?.message;
      if (message) return String(message);
      if (typeof value.message === 'string') return value.message;
    }
  } catch { /* The original error text remains available below. */ }
  return stderr.trim() || stdout.trim() || fallback;
}

// Resolve the standard Windows component beneath the OS installation directory.
// Tool arguments cannot supply an executable, script, native root, or OS path.
export function getWindowsPowerShellPath(systemRoot = process.env.SystemRoot || process.env.WINDIR) {
  if (typeof systemRoot !== 'string' || !/^[a-z]:[\\/]/i.test(systemRoot) || /[\x00-\x1f"]/.test(systemRoot)) {
    throw new Error('A valid absolute Windows SystemRoot is required.');
  }
  return win32.join(win32.normalize(systemRoot), 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

// Dependency injection is available only to imported unit tests.
export function createPowerShellRunner({ spawnImpl = spawn, timeoutMs = ACTION_TIMEOUT_MS, maxOutputBytes = MAX_OUTPUT_BYTES } = {}) {
  return async function runAction(action, args = {}) {
    if (![...actionByTool.values()].includes(action)) throw new Error('Unknown guard action.');
    exactKeys(args, booleanActions.has(action) ? ['enabled'] : [], 'Action arguments');
    if (booleanActions.has(action) && typeof args.enabled !== 'boolean') throw new Error('enabled must be a boolean.');
    const argv = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', BRIDGE, '-Action', action];
    if (booleanActions.has(action)) argv.push('-Enabled', args.enabled ? 'true' : 'false');
    const powershell = getWindowsPowerShellPath();

    return await new Promise((resolveResult, reject) => {
      let child;
      let finished = false;
      let timer;
      let outputBytes = 0;
      const stdout = [];
      const stderr = [];
      const finish = (error, result) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (error) reject(error); else resolveResult(result);
      };
      const killAndFail = message => {
        // A bridge can already have submitted a native request before timing
        // out. Never describe a bridge timeout as cancellation of that request.
        try { child?.kill(); } catch { /* Preserve the actual failure. */ }
        finish(new Error(message));
      };
      const capture = destination => chunk => {
        if (finished) return;
        const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        outputBytes += data.length;
        if (outputBytes > maxOutputBytes) {
          killAndFail('Guard bridge output exceeded the limit. A previously submitted request may still be processed; inspect guard_status before retrying.');
        } else destination.push(data);
      };
      try {
        child = spawnImpl(powershell, argv, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      } catch (error) {
        finish(new Error(`Cannot start Windows PowerShell: ${error.message}`));
        return;
      }
      child.stdout.on('data', capture(stdout));
      child.stderr.on('data', capture(stderr));
      child.on('error', error => finish(new Error(`Cannot run guard bridge: ${error.message}`)));
      child.on('close', (code, signal) => {
        if (finished) return;
        const out = Buffer.concat(stdout).toString('utf8').replace(/^\uFEFF/, '').trim();
        const err = Buffer.concat(stderr).toString('utf8').trim();
        if (code !== 0) {
          finish(new Error(bridgeErrorMessage(out, err, `Guard bridge exited with code ${code}${signal ? ` (${signal})` : ''}.`)));
          return;
        }
        try {
          const value = JSON.parse(out);
          if (!isObject(value)) throw new Error('Expected a JSON object.');
          finish(null, value);
        } catch {
          finish(new Error('Guard bridge returned invalid JSON. A submitted request may still be processed; inspect guard_status before retrying.'));
        }
      });
      timer = setTimeout(() => killAndFail('Guard bridge timed out. A submitted request may still be processed; inspect guard_status before retrying.'), timeoutMs);
      timer.unref?.();
    });
  };
}

export function startServer({ input = process.stdin, output = process.stdout, error = process.stderr, runAction = createPowerShellRunner() } = {}) {
  const reader = createInterface({ input, crlfDelay: Infinity });
  const send = value => output.write(`${JSON.stringify(value)}\n`);
  const rpcError = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

  async function handle(message) {
    if (!isObject(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string' || (Object.hasOwn(message, 'id') && !(typeof message.id === 'string' || (typeof message.id === 'number' && Number.isFinite(message.id))))) {
      rpcError(null, -32600, 'Invalid JSON-RPC request.');
      return;
    }
    if (!Object.hasOwn(message, 'id')) return; // Notifications never run controls.
    const { id, method } = message;
    try {
      let result;
      switch (method) {
        case 'initialize': {
          const params = message.params;
          if (!isObject(params) || typeof params.protocolVersion !== 'string') throw new RpcError(-32602, 'initialize requires protocolVersion.');
          result = {
            protocolVersion: SUPPORTED_PROTOCOLS.has(params.protocolVersion) ? params.protocolVersion : '2025-06-18',
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: 'codex-shutdown-guard', version: '1.1.2' },
            instructions: 'Uses the existing Windows Codex Shutdown Guard. Status is read-only. Controls require an explicit tool call; native queued requests need later status inspection. Arming can cause real PC shutdown.',
          };
          break;
        }
        case 'ping':
          if (message.params !== undefined) exactKeys(message.params, ['_meta'], 'ping params');
          result = {};
          break;
        case 'tools/list':
          if (message.params !== undefined) exactKeys(message.params, ['cursor', '_meta'], 'tools/list params');
          result = { tools };
          break;
        case 'tools/call': {
          const params = message.params;
          exactKeys(params, ['name', 'arguments', '_meta'], 'tools/call params');
          if (typeof params.name !== 'string' || !actionByTool.has(params.name)) throw new RpcError(-32602, 'Unknown guard tool.');
          const args = params.arguments === undefined ? {} : params.arguments;
          const isAutoStart = booleanActions.has(actionByTool.get(params.name));
          exactKeys(args, isAutoStart ? ['enabled'] : [], 'Tool arguments');
          if (isAutoStart && typeof args.enabled !== 'boolean') throw new RpcError(-32602, 'enabled is required and must be a boolean.');
          try {
            const value = await runAction(actionByTool.get(params.name), args);
            if (!isObject(value)) throw new Error('Guard bridge returned a non-object result.');
            result = { content: [{ type: 'text', text: JSON.stringify(value, null, 2) }], structuredContent: value, isError: value.ok === false };
          } catch (failure) {
            result = { content: [{ type: 'text', text: failure.message || String(failure) }], isError: true };
          }
          break;
        }
        default:
          throw new RpcError(-32601, 'Method not found.');
      }
      send({ jsonrpc: '2.0', id, result });
    } catch (failure) {
      if (failure instanceof RpcError) rpcError(id, failure.code, failure.message);
      else {
        error.write(`Guard MCP request failed: ${failure.message || String(failure)}\n`);
        rpcError(id, -32603, 'Internal server error.');
      }
    }
  }

  reader.on('line', line => {
    if (!line.trim()) return;
    if (Buffer.byteLength(line, 'utf8') > MAX_INPUT_BYTES) {
      rpcError(null, -32600, 'JSON-RPC input line exceeds the limit.');
      return;
    }
    let message;
    try { message = JSON.parse(line); }
    catch { rpcError(null, -32700, 'Parse error.'); return; }
    void handle(message);
  });
  reader.on('error', failure => error.write(`Guard MCP input failed: ${failure.message}\n`));
  return reader;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) startServer();
