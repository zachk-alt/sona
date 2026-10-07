import { spawn } from 'node:child_process';
import { access, mkdtemp, realpath, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { BridgeError, fail } from './errors.mjs';
import { cliArguments, parseCLIOutput, runProcess } from './cleanup.mjs';

// Inputs, replies and model metadata exist only in memory. Do not enable a
// debug stream, output file, resumed session or transport event log here.
export function assistantEnvironment(env) {
  const clean = { ...env, NO_COLOR: '1', CI: '1', RUST_LOG: 'off',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1',
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: 'false', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' };
  for (const name of Object.keys(clean)) {
    if (/^(?:OTEL_|CLAUDE_CODE_DEBUG|CODEX_THREAD_ID$|MAX_THINKING_TOKENS$|CLAUDE_CODE_EFFORT_LEVEL$|CLAUDE_CODE_DISABLE_THINKING$|CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING$)/u.test(name)) delete clean[name];
  }
  return clean;
}

// Only SDKAssistantMessage.error scalars or API error.type values qualify.
// Never inspect error messages, request IDs, status text or nested diagnostics.
// https://code.claude.com/docs/en/agent-sdk/typescript#sdkassistantmessage
// https://platform.claude.com/docs/en/api/errors
export function claudeErrorReason(error) {
  const code = typeof error === 'string' ? error
    : error && typeof error === 'object' && !Array.isArray(error) ? error.type : undefined;
  switch (code) {
    case 'authentication_failed': case 'authentication_error': return 'authentication_failed';
    case 'oauth_org_not_allowed': case 'permission_error': return 'provider_access_denied';
    case 'billing_error': return 'billing_error';
    case 'rate_limit': case 'rate_limit_error': return 'rate_limited';
    case 'invalid_request': case 'invalid_request_error': case 'request_too_large': case 'not_found_error': return 'provider_request_rejected';
    case 'model_not_found': return 'assistant_model_unavailable';
    case 'server_error': case 'api_error': case 'overloaded_error': return 'provider_unavailable';
    case 'max_output_tokens': return 'incomplete_response';
    case 'timeout_error': return 'timeout';
    default: return 'provider_error';
  }
}

export function claudeAssistantArgs(model, effort, system = '') {
  const args = ['-p', '--safe-mode', '--no-chrome', '--tools', '', '--disallowedTools', '*',
    '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--no-session-persistence',
    '--disable-slash-commands', '--settings', '{"disableAllHooks":true,"promptSuggestionEnabled":false}',
    '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose'];
  if (model) args.push('--model', model);
  if (effort && effort !== 'default') args.push('--effort', effort);
  if (system) args.push('--system-prompt', system);
  return args;
}

function kill(child) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === 'win32') {
    const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true, shell: false });
    killer.on('error', () => child.kill());
  } else { try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); } }
}

// A bounded JSON-lines channel for control initialization and at most one turn.
// Only callers select harmless metadata from initialization replies; account
// objects and provider diagnostic bodies are never returned or logged.
async function channel(launch, args, { env, signal, timeoutMs }, body) {
  const scratch = await mkdtemp(path.join(tmpdir(), 'sona-assistant-'));
  let child;
  try {
    child = spawn(launch.command, [...launch.prefix, ...args], { cwd: scratch, env: assistantEnvironment(env),
      stdio: ['pipe', 'pipe', 'ignore'], shell: false, windowsHide: true, detached: process.platform !== 'win32' });
    let pending = [], queued = [], error, buffer = '', received = 0, closed = false;
    const reject = (reason) => { if (error) return; error = new BridgeError(reason); for (const wait of pending) wait.reject(error); pending = []; kill(child); };
    const timer = setTimeout(() => reject('timeout'), timeoutMs);
    const cancel = () => reject('cancelled'); signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    child.on('error', () => reject('cli_launch_failed'));
    child.stdin.on('error', () => reject('cli_stdin_failed'));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      received += Buffer.byteLength(chunk);
      if (received > 2 * 1024 * 1024) return reject('output_too_large');
      buffer += chunk;
      while (buffer.includes('\n')) {
        const newline = buffer.indexOf('\n'), line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let value; try { value = JSON.parse(line); } catch { reject('invalid_response'); return; }
        const wait = pending.shift(); if (wait) wait.resolve(value); else queued.push(value);
      }
    });
    let exitResolve; const exit = new Promise((resolve) => { exitResolve = resolve; });
    child.on('close', (code) => { closed = true; exitResolve(code); if (pending.length) reject('cli_closed'); });
    const api = {
      send(value) { if (error) throw error; child.stdin.write(JSON.stringify(value) + '\n'); },
      next() { if (error) return Promise.reject(error); if (queued.length) return Promise.resolve(queued.shift()); if (closed) return Promise.reject(new BridgeError('cli_closed')); return new Promise((resolve, reject) => pending.push({ resolve, reject })); },
      async finish() { child.stdin.end(); const code = await exit; if (error) throw error; if (code !== 0) fail('cli_failed'); },
    };
    try { const result = await body(api); if (error) throw error; return result; }
    finally { clearTimeout(timer); signal?.removeEventListener('abort', cancel); child.stdin.destroy(); child.stdout.destroy(); kill(child); }
  } finally { if (child) kill(child); await rm(scratch, { recursive: true, force: true }).catch(() => {}); }
}

export async function claudeModels(launch, options) {
  return channel(launch, claudeAssistantArgs(), options, async (io) => {
    io.send({ type: 'control_request', request_id: 'sona_models', request: { subtype: 'initialize' } });
    for (;;) {
      const value = await io.next();
      if (value.type === 'control_request') fail('unexpected_provider_request');
      if (value.type === 'error' || value.error != null) fail(claudeErrorReason(value.error));
      if (value.type === 'control_response' && value.response?.request_id === 'sona_models') {
        if (value.response.subtype !== 'success' || !Array.isArray(value.response.response?.models)) fail('catalog_unavailable');
        return value.response.response.models.map(({ value, resolvedModel, displayName, supportsEffort, supportedEffortLevels }) =>
          ({ value, resolvedModel, displayName, supportsEffort, supportedEffortLevels }));
      }
    }
  });
}

export async function claudeAssistant(launch, { model, effort, system, payload, images = [], ...options }) {
  return channel(launch, claudeAssistantArgs(model, effort, system), options, async (io) => {
    io.send({ type: 'user', message: { role: 'user', content: [
      { type: 'text', text: JSON.stringify(payload) },
      ...images.map((image) => ({ type: 'image', source: { type: 'base64', media_type: image.mimeType, data: image.dataBase64 } })),
    ] }, parent_tool_use_id: null });
    let initialized = false, actualModel = null;
    for (;;) {
      const value = await io.next();
      if (value.type === 'control_request') fail('unexpected_provider_request');
      if (value.type === 'system' && value.subtype === 'init') {
        if (!Array.isArray(value.tools) || value.tools.length || !Array.isArray(value.mcp_servers) || value.mcp_servers.length) fail('provider_tools_enabled');
        initialized = true;
      }
      if (value.type === 'assistant') {
        const content = value.message?.content;
        if (content != null && !Array.isArray(content)) fail('invalid_response');
        if (content?.some((item) => ['tool_use', 'server_tool_use'].includes(item.type))) fail('provider_tool_or_error');
      }
      if (value.type === 'error' || value.error != null) fail(claudeErrorReason(value.error));
      if (value.type === 'assistant') {
        if (value.message?.stop_reason === 'max_tokens') fail('incomplete_response');
        if (typeof value.message?.model === 'string') actualModel = value.message.model;
      }
      if (value.type === 'result') {
        if (!initialized || !actualModel || value.is_error !== false || value.subtype !== 'success' ||
            typeof value.result !== 'string' || !value.result.trim() || value.num_turns !== 1 ||
            (value.errors != null && (!Array.isArray(value.errors) || value.errors.length)) ||
            (value.permission_denials != null && (!Array.isArray(value.permission_denials) || value.permission_denials.length))) fail('invalid_response');
        const canonical = model.replace(/\[1m\]$/u, '');
        if (canonical.startsWith('claude-') && actualModel !== canonical && !actualModel.startsWith(canonical + '-')) fail('unexpected_model');
        await io.finish(); return value.result;
      }
    }
  });
}

// Model metadata is read before any thread exists. No thread/start, turn/start,
// MCP discovery or account/read request is sent by this catalog path.
export async function codexModels(launch, options) {
  const args = ['app-server', '--stdio', '-c', 'analytics.enabled=false', '-c', 'history.persistence="none"',
    '-c', 'features.hooks=false', '-c', 'features.apps=false', '-c', 'features.plugins=false', '-c', 'features.shell_snapshot=false'];
  // GUI apps may have no Node on PATH. Resolve the same npm-owned native
  // binary as screen requests instead of running an env-node wrapper.
  return channel(await codexNative(launch), args, options, async (io) => {
    io.send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'sona', version: '1' }, capabilities: {} } });
    for (;;) { const value = await io.next(); if (value.id === 1) { if (value.error) fail('catalog_unavailable'); break; } }
    io.send({ method: 'initialized', params: {} });
    const models = []; let cursor = null, id = 2;
    do {
      io.send({ id, method: 'model/list', params: { limit: 100, includeHidden: false, ...(cursor ? { cursor } : {}) } });
      let reply; for (;;) { const value = await io.next(); if (value.id === id) { reply = value; break; } }
      if (reply.error || !Array.isArray(reply.result?.data)) fail('catalog_unavailable');
      models.push(...reply.result.data); if (models.length > 256) fail('catalog_too_large');
      cursor = reply.result.nextCursor; id++;
    } while (cursor);
    return models.map(({ model, displayName, inputModalities, supportedReasoningEfforts, defaultReasoningEffort }) =>
      ({ model, displayName, inputModalities, supportedReasoningEfforts, defaultReasoningEffort }));
  });
}

export async function codexNative(launch) {
  const candidate = launch.prefix[0] ?? await realpath(launch.command).catch(() => launch.command);
  if (!candidate.endsWith('/codex.js') && !candidate.endsWith('\\codex.js')) return launch;
  const target = process.platform === 'darwin' ? `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-apple-darwin`
    : process.platform === 'win32' ? `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-pc-windows-msvc`
      : `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-unknown-linux-musl`;
  const packageName = `@openai/codex-${process.platform}-${process.arch}`;
  const require = createRequire(candidate);
  let vendor;
  try { vendor = path.join(path.dirname(require.resolve(`${packageName}/package.json`)), 'vendor'); }
  catch { vendor = path.join(path.dirname(candidate), '..', 'vendor'); }
  const command = path.join(vendor, target, 'bin', process.platform === 'win32' ? 'codex.exe' : 'codex');
  try { await access(command); return { command, prefix: [] }; } catch { fail('codex_native_not_found'); }
}

// std::fs::read loads local image bytes, then Codex decodes a memory Cursor.
// The inherited descriptor / private named pipe contains no on-disk image.
async function codexRun(launch, args, input, images, { env, signal, timeoutMs, cwd }) {
  const servers = [], sockets = [], paths = [];
  try {
    if (process.platform === 'win32') for (const image of images) {
      const name = `\\\\.\\pipe\\sona-image-${randomUUID()}`;
      let delivered = false;
      const server = createServer((socket) => {
        sockets.push(socket);
        if (delivered) { socket.destroy(); return; }
        delivered = true; socket.on('error', () => {}); socket.end(Buffer.from(image.dataBase64, 'base64'));
      });
      servers.push(server); await new Promise((resolve, reject) => { server.once('error', reject); server.listen(name, resolve); }); paths.push(name);
    }
    else images.forEach((_, index) => paths.push(`/dev/fd/${index + 3}`));
    const finalArgs = [...args.slice(0, -1), ...paths.flatMap((image) => ['--image', image]), '-'];
    return await new Promise((resolve, reject) => {
      const child = spawn(launch.command, [...launch.prefix, ...finalArgs], { env: assistantEnvironment(env), cwd,
        stdio: ['pipe', 'pipe', 'ignore', ...(process.platform === 'win32' ? [] : images.map(() => 'pipe'))],
        shell: false, windowsHide: true, detached: process.platform !== 'win32' });
      let done = false, output = '', bytes = 0;
      const finish = (error) => {
        if (done) return; done = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel);
        for (const stream of child.stdio) stream?.destroy(); kill(child);
        if (error) reject(new BridgeError(error)); else resolve(output);
      };
      const timer = setTimeout(() => finish('timeout'), timeoutMs), cancel = () => finish('cancelled');
      signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
      child.on('error', () => finish('cli_launch_failed')); child.stdin.on('error', () => finish('cli_stdin_failed'));
      child.stdout.setEncoding('utf8'); child.stdout.on('data', (chunk) => { bytes += Buffer.byteLength(chunk); if (bytes > 2 * 1024 * 1024) finish('output_too_large'); else output += chunk; });
      child.on('close', (code) => finish(code === 0 ? null : 'cli_failed'));
      if (process.platform !== 'win32') images.forEach((image, index) => { const stream = child.stdio[index + 3]; stream.on('error', () => finish('image_pipe_failed')); stream.end(Buffer.from(image.dataBase64, 'base64')); });
      child.stdin.end(JSON.stringify(input));
    });
  } finally { for (const socket of sockets) socket.destroy(); for (const server of servers) server.close(); }
}

export async function codexRewrite(launch, { model, effort, payload, env, signal, timeoutMs }) {
  const scratch = await mkdtemp(path.join(tmpdir(), 'sona-assistant-rewrite-'));
  try {
    const args = cliArguments('codex', model, 'rewrite', '', scratch);
    const index = args.findIndex((arg) => arg.startsWith('model_reasoning_effort='));
    args[index] = `model_reasoning_effort=${JSON.stringify(effort)}`;
    return parseCLIOutput('codex', await runProcess(await codexNative(launch), args, JSON.stringify(payload), { env: assistantEnvironment(env), cwd: scratch, signal, timeoutMs }));
  } finally { await rm(scratch, { recursive: true, force: true }).catch(() => {}); }
}

export async function codexAssistant(launch, { model, effort, system, payload, images, env, signal, timeoutMs }) {
  const scratch = await mkdtemp(path.join(tmpdir(), 'sona-assistant-'));
  try {
    const args = cliArguments('codex', model, 'assistant', '', scratch);
    args[args.findIndex((arg) => arg.startsWith('model_reasoning_effort='))] = `model_reasoning_effort=${JSON.stringify(effort)}`;
    // This is a bridge-authored constant prompt, never user/image content.
    args.splice(args.length - 1, 0, '-c', `developer_instructions=${JSON.stringify(system)}`);
    const output = await codexRun(await codexNative(launch), args, payload, images, { env, signal, timeoutMs, cwd: scratch });
    return parseCLIOutput('codex', output);
  } finally { await rm(scratch, { recursive: true, force: true }).catch(() => {}); }
}
