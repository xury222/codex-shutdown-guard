import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { createPowerShellRunner, getWindowsPowerShellPath, startServer } from '../server/index.mjs';

function harness(runAction = async action => ({ ok: true, action, queued: action !== 'Inspect' })) {
  const input = new PassThrough();
  const output = new PassThrough();
  const error = new PassThrough();
  const messages = [];
  let pending = '';
  output.on('data', chunk => {
    pending += chunk.toString();
    let end;
    while ((end = pending.indexOf('\n')) !== -1) {
      messages.push(JSON.parse(pending.slice(0, end)));
      pending = pending.slice(end + 1);
    }
  });
  const server = startServer({ input, output, error, runAction });
  return {
    messages,
    send: message => input.write(typeof message === 'string' ? `${message}\n` : `${JSON.stringify(message)}\n`),
    flush: () => new Promise(resolve => setImmediate(resolve)),
    close: () => { server.close(); input.destroy(); output.destroy(); error.destroy(); },
  };
}

function fakeSpawn(result) {
  const calls = [];
  const spawnImpl = (exe, argv, options) => {
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kill = () => { child.killed = true; return true; };
    calls.push({ exe, argv, options, child });
    setImmediate(() => result(child));
    return child;
  };
  return { calls, spawnImpl };
}

test('initialize/ping/list perform no native action and negotiate protocol', async () => {
  let calls = 0;
  const h = harness(async () => { calls++; return { ok: true }; });
  try {
    h.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'test', version: '1' } } });
    h.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    h.send({ jsonrpc: '2.0', id: 2, method: 'ping' });
    h.send({ jsonrpc: '2.0', id: 3, method: 'tools/list' });
    await h.flush();
    assert.equal(calls, 0);
    assert.equal(h.messages.length, 3);
    assert.equal(h.messages[0].result.protocolVersion, '2025-03-26');
    assert.deepEqual(h.messages[1].result, {});
    const tools = h.messages[2].result.tools;
    assert.equal(tools.length, 9);
    assert.deepEqual(tools.filter(tool => tool.annotations.readOnlyHint).map(tool => tool.name), ['guard_status']);
    assert.equal(tools.find(tool => tool.name === 'guard_arm').annotations.destructiveHint, true);
    assert.ok(tools.every(tool => tool.inputSchema.additionalProperties === false));
    assert.deepEqual(tools.find(tool => tool.name === 'guard_set_codex_autostart').inputSchema.required, ['enabled']);
    assert.deepEqual(tools.find(tool => tool.name === 'guard_set_guard_autostart').inputSchema.required, ['enabled']);
    assert.match(tools.find(tool => tool.name === 'guard_set_guard_autostart').description, /unarmed/);
    h.send({ jsonrpc: '2.0', id: 4, method: 'initialize', params: { protocolVersion: 'unsupported' } });
    await h.flush();
    assert.equal(h.messages.at(-1).result.protocolVersion, '2025-06-18');
  } finally { h.close(); }
});

test('strict schemas reject path injection, wrong boolean, unknown keys and tools', async () => {
  const calls = [];
  const h = harness(async (...args) => { calls.push(args); return { ok: true }; });
  try {
    const bad = [
      { name: 'guard_status', arguments: { Root: 'C:\\other' } },
      { name: 'guard_arm', arguments: { action: 'Stop' } },
      { name: 'guard_set_codex_autostart', arguments: { enabled: 'false' } },
      { name: 'guard_set_codex_autostart', arguments: {} },
      { name: 'guard_set_codex_autostart', arguments: { enabled: true, path: 'x' } },
      { name: 'guard_set_guard_autostart', arguments: { enabled: 'false' } },
      { name: 'guard_set_guard_autostart', arguments: {} },
      { name: 'guard_set_guard_autostart', arguments: { enabled: true, Root: 'C:\\escape' } },
      { name: 'unknown', arguments: {} },
      { name: 'guard_status', arguments: [] },
      { name: 'guard_status', arguments: null },
      { name: 'guard_status', arguments: {}, root: 'x' },
    ];
    bad.forEach((params, id) => h.send({ jsonrpc: '2.0', id, method: 'tools/call', params }));
    await h.flush();
    assert.equal(calls.length, 0);
    assert.equal(h.messages.length, bad.length);
    assert.ok(h.messages.every(message => message.error.code === -32602));
  } finally { h.close(); }
});

test('nine explicit tool calls map to fixed actions and preserve queued results', async () => {
  const calls = [];
  const h = harness(async (action, args) => { calls.push({ action, args }); return { ok: true, action, queued: action !== 'Inspect' }; });
  try {
    const cases = [
      ['guard_status', 'Inspect'], ['guard_show', 'Show'], ['guard_arm', 'Arm'], ['guard_disarm', 'Disarm'],
      ['guard_rescan', 'Rescan'], ['guard_stop', 'Stop'], ['guard_launch_codex', 'LaunchCodex'], ['guard_set_codex_autostart', 'SetAutoStartCodex'],
      ['guard_set_guard_autostart', 'SetAutoStartGuard'],
    ];
    cases.forEach(([name], id) => h.send({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: name.endsWith('autostart') ? { enabled: false } : {} } }));
    // A malformed client notification must never execute a shutdown control.
    h.send({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'guard_arm', arguments: {} } });
    await h.flush();
    assert.deepEqual(calls.map(call => call.action), cases.map(([, action]) => action));
    assert.deepEqual(calls.at(-1).args, { enabled: false });
    assert.equal(h.messages.length, cases.length);
    assert.equal(h.messages.find(message => message.id === 2).result.structuredContent.queued, true);
    assert.ok(h.messages.every(message => message.result.isError === false));
  } finally { h.close(); }
});

test('protocol errors and bridge errors use their respective response channels', async () => {
  const h = harness(async () => { throw new Error('native installation missing'); });
  try {
    h.send('{');
    h.send('null');
    h.send({ jsonrpc: '2.0', id: 1, method: 'missing' });
    h.send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'guard_status' } });
    await h.flush();
    assert.equal(h.messages[0].error.code, -32700);
    assert.equal(h.messages[1].error.code, -32600);
    assert.equal(h.messages[2].error.code, -32601);
    assert.equal(h.messages[3].result.isError, true);
    assert.match(h.messages[3].result.content[0].text, /native installation missing/);
  } finally { h.close(); }
});

test('PowerShell uses the Windows OS path and argument array without shell interpolation', async () => {
  const f = fakeSpawn(child => { child.stdout.end(JSON.stringify({ ok: true, queued: true })); child.emit('close', 0, null); });
  const runAction = createPowerShellRunner({ spawnImpl: f.spawnImpl });
  await runAction('Inspect');
  await runAction('SetAutoStartCodex', { enabled: false });
  await runAction('SetAutoStartCodex', { enabled: true });
  await runAction('SetAutoStartGuard', { enabled: false });
  await runAction('SetAutoStartGuard', { enabled: true });
  assert.equal(f.calls[0].exe, getWindowsPowerShellPath());
  assert.deepEqual(f.calls[0].argv.slice(0, 6), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', f.calls[0].argv[5]]);
  assert.match(f.calls[0].argv[5], /skills[\\/]codex-shutdown-guard[\\/]scripts[\\/]Invoke-Guard\.ps1$/);
  assert.deepEqual(f.calls[0].argv.slice(6), ['-Action', 'Inspect']);
  assert.deepEqual(f.calls[1].argv.slice(-4), ['-Action', 'SetAutoStartCodex', '-Enabled', 'false']);
  assert.deepEqual(f.calls[2].argv.slice(-2), ['-Enabled', 'true']);
  assert.deepEqual(f.calls[3].argv.slice(-4), ['-Action', 'SetAutoStartGuard', '-Enabled', 'false']);
  assert.deepEqual(f.calls[4].argv.slice(-2), ['-Enabled', 'true']);
  assert.equal(f.calls[0].options.shell, false);
  assert.equal(f.calls[0].options.windowsHide, true);
  await assert.rejects(runAction('Inspect', { root: 'D:\\escape' }), /only/);
  await assert.rejects(runAction('SetAutoStartCodex', { enabled: 'false' }), /boolean/);
  await assert.rejects(runAction('SetAutoStartGuard', { enabled: 'false' }), /boolean/);
  await assert.rejects(runAction('Stop; shutdown.exe /s'), /Unknown/);
  assert.equal(f.calls.length, 5);
});

test('PowerShell path follows non-C Windows roots and rejects unsafe OS paths', () => {
  assert.equal(getWindowsPowerShellPath('E:\\Windows'), 'E:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
  for (const root of ['', 'Windows', 'C:Windows', '\\Windows', '\\\\host\\Windows', 'C:\\Windows" -Command shutdown', 'C:\\Windows\n']) {
    assert.throws(() => getWindowsPowerShellPath(root), /SystemRoot/);
  }
});

test('PowerShell bridge failures, malformed output and byte limits are bounded', async () => {
  for (const [emit, expected] of [
    [child => { child.stdout.end('{"ok":false,"error":"native failure"}'); child.emit('close', 2, null); }, /native failure/],
    [child => { child.stdout.end('not JSON'); child.emit('close', 0, null); }, /invalid JSON/],
    [child => { child.stdout.write('x'.repeat(65)); }, /exceeded the limit/],
    [child => { child.emit('error', new Error('spawn unavailable')); }, /spawn unavailable/],
  ]) {
    const f = fakeSpawn(emit);
    await assert.rejects(createPowerShellRunner({ spawnImpl: f.spawnImpl, maxOutputBytes: 64 })('Inspect'), expected);
  }
});

test('timeout kills only bridge and accurately leaves native request outcome unknown', async () => {
  const f = fakeSpawn(() => {});
  // Keep the test event loop alive because the production timeout is unref'ed.
  const keepAlive = setTimeout(() => {}, 200);
  try {
    await assert.rejects(createPowerShellRunner({ spawnImpl: f.spawnImpl, timeoutMs: 10 })('Inspect'), /timed out.*may still be processed/);
    assert.equal(f.calls[0].child.killed, true);
  } finally { clearTimeout(keepAlive); }
});
