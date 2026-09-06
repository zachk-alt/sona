import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { GEMINI_MODEL, GEMINI_VERSION, geminiInput, geminiVersion, parseGeminiOutput, prepareGemini } from './gemini-cli.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
export const MAX_INPUT = 64 * 1024;
const MAX_RESPONSE = 1024 * 1024;
export const PROVIDERS = Object.freeze({
  claude: { transport: 'cli', model: 'claude-haiku-4-5-20251001', executable: 'claude' },
  codex: { transport: 'cli', model: 'gpt-5.6-luna', executable: 'codex' },
  'gemini-cli': { transport: 'cli', model: GEMINI_MODEL, executable: 'gemini' },
  anthropic: { transport: 'anthropic', model: 'claude-haiku-4-5-20251001', endpoint: 'https://api.anthropic.com/v1/messages', apiKeyEnv: 'ANTHROPIC_API_KEY' },
  openai: { transport: 'compatible', model: 'gpt-5-nano-2025-08-07', endpoint: 'https://api.openai.com/v1/chat/completions', apiKeyEnv: 'OPENAI_API_KEY' },
  gemini: { transport: 'compatible', model: 'gemini-2.5-flash-lite', endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions', apiKeyEnv: 'GEMINI_API_KEY' },
  kimi: { transport: 'compatible', model: 'kimi-k2.6', endpoint: 'https://api.moonshot.ai/v1/chat/completions', apiKeyEnv: 'MOONSHOT_API_KEY' },
  grok: { transport: 'responses', model: 'grok-4.6', endpoint: 'https://api.x.ai/v1/responses', apiKeyEnv: 'XAI_API_KEY' },
  opencode: { transport: 'responses', model: 'gpt-5-nano', endpoint: 'https://opencode.ai/zen/v1/responses', apiKeyEnv: 'OPENCODE_API_KEY' },
  custom: { transport: 'compatible' },
});

export class BridgeError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = (code) => { throw new BridgeError(code); };
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const boundedString = (value, max) => typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f]/u.test(value);

export function parseConfig(config = {}) {
  if (!object(config) || (config.ai !== undefined && !object(config.ai))) fail('invalid_config');
  const ai = { provider: 'auto', model: 'economy', timeoutMs: 15000, ...config.ai };
  if (!['auto', 'none', ...Object.keys(PROVIDERS)].includes(ai.provider)) fail('invalid_provider');
  if (!boundedString(ai.model, 150) || !Number.isInteger(ai.timeoutMs) || ai.timeoutMs < 250 || ai.timeoutMs > 30000) fail('invalid_config');
  // Credential values have no place in the config. Only their environment names are accepted.
  const allowed = new Set(['provider', 'model', 'timeoutMs', 'executable', 'args', 'endpoint', 'apiKeyEnv']);
  if (Object.keys(ai).some((key) => !allowed.has(key))) fail('unknown_ai_setting');
  if (ai.executable !== undefined && (!boundedString(ai.executable, 4096) || !path.isAbsolute(ai.executable))) fail('invalid_executable');
  // Prefix arguments support a Node CLI launcher, not arbitrary provider flags.
  // Mandatory safety options are always authored by this bridge.
  if (ai.args !== undefined && (!ai.executable || !Array.isArray(ai.args) || ai.args.length !== 1 ||
      !boundedString(ai.args[0], 4096) || !path.isAbsolute(ai.args[0]) || !/\.(?:mjs|cjs|js)$/iu.test(ai.args[0]) ||
      !/^node(?:\.exe)?$/iu.test(path.basename(ai.executable)))) fail('invalid_launcher_args');
  if (ai.endpoint !== undefined && !boundedString(ai.endpoint, 2048)) fail('invalid_endpoint');
  if (ai.apiKeyEnv !== undefined && !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/u.test(ai.apiKeyEnv)) fail('invalid_key_environment_name');
  if (config.vocabulary !== undefined && (!Array.isArray(config.vocabulary) || config.vocabulary.length > 256 ||
      config.vocabulary.some((value) => !boundedString(value, 100)))) fail('invalid_vocabulary');
  return { ...ai, vocabulary: config.vocabulary ?? [] };
}

async function executable(file) {
  try { await access(file, process.platform === 'win32' ? constants.F_OK : constants.X_OK); return true; } catch { return false; }
}

export async function resolveCLI(provider, config = {}, env = process.env) {
  const name = PROVIDERS[provider].executable;
  const home = homedir();
  const directories = [...(env.PATH ?? env.Path ?? '').split(path.delimiter),
    path.join(home, '.local', 'bin'), path.join(home, '.claude', 'local'),
    '/opt/homebrew/bin', '/usr/local/bin', path.join(home, '.bun', 'bin'), path.join(home, '.volta', 'bin')];
  if (env.APPDATA) directories.push(path.join(env.APPDATA, 'npm'));
  if (env.LOCALAPPDATA) directories.push(path.join(env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links'));
  const extensions = process.platform === 'win32' ? ['.exe', '.cmd', ''] : [''];
  const candidates = config.executable ? [config.executable] : directories.filter(Boolean).flatMap((dir) => extensions.map((ext) => path.join(dir, name + ext)));
  for (const candidate of candidates) {
    if (!await executable(candidate)) continue;
    if (/\.cmd$/iu.test(candidate)) {
      // Do not invoke cmd.exe or interpolate shell text. Npm's documented Windows
      // package layouts can be launched directly by Node instead of a batch shim.
      const relative = provider === 'codex' ? '@openai/codex/bin/codex.js' : provider === 'gemini-cli'
        ? '@google/gemini-cli/bundle/gemini.js' : '@anthropic-ai/claude-code/cli.js';
      const script = path.join(path.dirname(candidate), 'node_modules', relative);
      try { await access(script); return { command: process.execPath, prefix: [script] }; } catch { continue; }
    }
    if (/\.(?:bat|ps1)$/iu.test(candidate)) continue;
    return { command: candidate, prefix: config.args ?? [] };
  }
  return null;
}

async function select(config, env) {
  let provider = config.provider;
  if (provider === 'auto') {
    if (config.executable || config.args || config.endpoint || config.apiKeyEnv || config.model !== 'economy') fail('auto_requires_defaults');
    // Availability is executable presence, never an account/key search or an API call.
    for (const candidate of ['claude', 'codex']) {
      const launch = await resolveCLI(candidate, {}, env);
      if (launch) return { provider: candidate, model: PROVIDERS[candidate].model, launch };
    }
    fail('no_supported_cli');
  }
  if (provider === 'none') return { provider };
  const preset = PROVIDERS[provider];
  const model = config.model === 'economy' ? preset.model : config.model;
  if (!model) fail('explicit_model_required');
  if (preset.transport === 'cli') {
    if (config.endpoint || config.apiKeyEnv) fail('cli_does_not_take_api_settings');
    const launch = await resolveCLI(provider, config, env);
    if (!launch) fail('cli_not_found');
    return { provider, model, launch };
  }
  if (config.executable || config.args) fail('api_provider_does_not_take_cli_settings');
  return { provider, model };
}

function childEnvironment(env) {
  const result = { ...env, NO_COLOR: '1', CI: '1', MAX_THINKING_TOKENS: '0',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1',
    DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', RUST_LOG: 'off' };
  for (const key of Object.keys(result)) {
    if (/^(?:OTEL_|CLAUDE_CODE_DEBUG|CODEX_THREAD_ID$)/u.test(key)) delete result[key];
  }
  return result;
}

export function cliArguments(provider, model, mode, system, scratch) {
  if (provider === 'claude') return ['-p', '--output-format', 'json', '--model', model,
    '--tools', '', '--disallowedTools', 'mcp__*', '--safe-mode', '--strict-mcp-config',
    '--no-session-persistence', '--disable-slash-commands', '--settings', '{"disableAllHooks":true}',
    '--system-prompt', system];
  const settings = {
    approval_policy: 'never', history: { persistence: 'none' }, model_reasoning_effort: 'low',
    model_provider: 'openai', model_instructions_file: path.join(ROOT, 'prompts', `${mode}.txt`),
    project_doc_max_bytes: 0, web_search: 'disabled', tools: { view_image: false },
    memories: { generate_memories: false, use_memories: false },
    features: { shell_tool: false, unified_exec: false, shell_snapshot: false, apps: false,
      plugins: false, hooks: false, multi_agent: false, computer_use: false, browser_use: false,
      browser_use_external: false, image_generation: false, code_mode_host: false,
      workspace_dependencies: false, goals: false, skill_mcp_dependency_install: false },
  };
  // TOML inline tables differ from JSON objects; pass flattened scalar keys only.
  const flatten = (value, prefix = '') => Object.entries(value).flatMap(([key, item]) =>
    object(item) ? flatten(item, prefix + key + '.') : ['-c', `${prefix}${key}=${JSON.stringify(item)}`]);
  return ['exec', '--json', '--ephemeral', '--ignore-user-config', '--ignore-rules',
    '--skip-git-repo-check', '--sandbox', 'read-only', '--color', 'never', '--cd', scratch,
    '--model', model, ...flatten(settings), '-'];
}

function terminateTree(child) {
  if (!child.pid) return;
  if (process.platform === 'win32') {
    const killer = spawn(path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe'),
      ['/pid', String(child.pid), '/T', '/F'], { shell: false, windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => { try { child.kill('SIGKILL'); } catch {} });
    killer.unref();
  } else {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch {} }
  }
}

export function runProcess(launch, args, input, { env, cwd, signal, timeoutMs }) {
  return new Promise((resolve, reject) => {
    let finished = false, size = 0, chunks = [];
    const child = spawn(launch.command, [...launch.prefix, ...args], {
      shell: false, cwd, env: childEnvironment(env), stdio: ['pipe', 'pipe', 'ignore'],
      windowsHide: true, detached: process.platform !== 'win32',
    });
    const finish = (error, output) => {
      if (finished) return;
      finished = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel);
      if (error) terminateTree(child);
      child.stdin.destroy(); child.stdout.destroy();
      if (error) reject(error); else resolve(output);
    };
    const cancel = () => finish(new BridgeError('cancelled'));
    const timer = setTimeout(() => finish(new BridgeError('timeout')), timeoutMs);
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) { cancel(); return; }
    child.on('error', () => finish(new BridgeError('launch_failed')));
    child.stdin.on('error', () => finish(new BridgeError('input_closed')));
    child.stdout.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_RESPONSE) finish(new BridgeError('response_too_large'));
      else chunks.push(chunk);
    });
    child.on('close', (code, exitSignal) => {
      if (code !== 0 || exitSignal) finish(new BridgeError('cli_failed'));
      else finish(null, Buffer.concat(chunks).toString('utf8'));
    });
    child.stdin.end(input);
  });
}

export function parseCLIOutput(provider, output) {
  if (provider === 'claude') {
    let frame; try { frame = JSON.parse(output); } catch { fail('invalid_response'); }
    if (!object(frame) || frame.type !== 'result' || frame.subtype !== 'success' || frame.is_error !== false ||
        frame.error != null || (frame.errors != null && (!Array.isArray(frame.errors) || frame.errors.length))) fail('provider_error');
    return frame.result;
  }
  let frames; try { frames = output.trim().split(/\r?\n/u).map((line) => JSON.parse(line)); } catch { fail('invalid_response'); }
  let text, complete = false;
  for (const frame of frames) {
    if (!object(frame) || frame.error != null || ['error', 'turn.failed'].includes(frame.type)) fail('provider_error');
    if (frame.type === 'item.started' || frame.type === 'item.completed') {
      if (!object(frame.item) || !['reasoning', 'agent_message'].includes(frame.item.type)) fail('unexpected_tool_event');
      if (frame.type === 'item.completed' && frame.item.type === 'agent_message') {
        if (text !== undefined) fail('multiple_messages');
        text = frame.item.text;
      }
    }
    if (frame.type === 'turn.completed') complete = true;
  }
  if (!complete) fail('incomplete_response');
  return text;
}

function endpointFor(provider, config) {
  let url;
  try { url = new URL(config.endpoint ?? PROVIDERS[provider].endpoint); } catch { fail('invalid_endpoint'); }
  const loopback = ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) || url.username || url.password || url.search || url.hash) fail('unsafe_endpoint');
  // Built-in providers cannot send an existing key to an arbitrary alternate host.
  // Use explicit custom for a different service, with its own environment name.
  if (provider !== 'custom' && url.origin !== new URL(PROVIDERS[provider].endpoint).origin) fail('provider_endpoint_mismatch');
  return { url, loopback };
}

export function apiRequest(provider, model, system, input) {
  const maxTokens = Math.min(4096, Math.max(256, Math.ceil(input.length / 2) + 256));
  if (provider === 'anthropic') return {
    model, max_tokens: maxTokens, system, messages: [{ role: 'user', content: input }], tools: [], stream: false,
  };
  if (PROVIDERS[provider].transport === 'responses') return {
    model, input: [{ role: 'system', content: system }, { role: 'user', content: input }],
    tools: [], tool_choice: 'none', stream: false, store: false, max_output_tokens: maxTokens,
    reasoning: { effort: model.startsWith('gpt-5-nano') ? 'minimal' : 'low' },
  };
  const body = { model, messages: [{ role: 'system', content: system }, { role: 'user', content: input }],
    stream: false, tool_choice: 'none' };
  // Omit tool definitions entirely: no local or server-side tools are offered.
  if (provider === 'openai') {
    Object.assign(body, { store: false, max_completion_tokens: maxTokens });
    if (/^(?:gpt-[56]|o[134])/u.test(model)) body.reasoning_effort = model.startsWith('gpt-5-nano') ? 'minimal' : 'low';
  }
  else Object.assign(body, { max_tokens: maxTokens });
  if (provider === 'gemini' && model.startsWith('gemini-2.5-')) body.reasoning_effort = 'none';
  if (provider === 'kimi' && model === 'kimi-k2.6') body.thinking = { type: 'disabled' };
  if (provider === 'kimi' && model.startsWith('kimi-k3')) body.reasoning_effort = 'low';
  return body;
}

export function parseAPIOutput(provider, frame, requestedModel) {
  if (!object(frame) || frame.error != null || frame.is_error === true) fail('provider_error');
  if (typeof frame.model !== 'string') fail('invalid_response');
  const snapshotSuffix = frame.model.startsWith(requestedModel + '-') ? frame.model.slice(requestedModel.length + 1) : '';
  if (frame.model !== requestedModel && !/^(?:\d{4}-\d{2}-\d{2}|\d{8})$/u.test(snapshotSuffix)) fail('model_changed');
  if (provider === 'anthropic') {
    if (frame.type !== 'message' || frame.role !== 'assistant' || frame.stop_reason !== 'end_turn' ||
        !Array.isArray(frame.content) || !frame.content.length || frame.content.some((part) => part.type !== 'text' || typeof part.text !== 'string')) fail('incomplete_response');
    return frame.content.map((part) => part.text).join('');
  }
  if (PROVIDERS[provider].transport === 'responses') {
    if (frame.status !== 'completed' || frame.incomplete_details != null || !Array.isArray(frame.output)) fail('incomplete_response');
    const messages = frame.output.filter((part) => part.type !== 'reasoning');
    if (messages.length !== 1 || messages[0].type !== 'message' || messages[0].role !== 'assistant' ||
        !Array.isArray(messages[0].content) || !messages[0].content.length ||
        messages[0].content.some((part) => part.type !== 'output_text' || typeof part.text !== 'string')) fail('invalid_response');
    return messages[0].content.map((part) => part.text).join('');
  }
  if (!Array.isArray(frame.choices) || frame.choices.length !== 1) fail('invalid_response');
  const choice = frame.choices[0], message = choice.message;
  if (choice.finish_reason !== 'stop' || !object(message) || message.role !== 'assistant' || message.refusal ||
      message.function_call || (message.tool_calls != null && (!Array.isArray(message.tool_calls) || message.tool_calls.length))) fail('incomplete_response');
  return message.content;
}

async function runAPI(provider, model, config, system, input, env, signal) {
  const { url, loopback } = endpointFor(provider, config);
  const keyName = config.apiKeyEnv ?? PROVIDERS[provider].apiKeyEnv;
  const key = keyName ? env[keyName] : undefined;
  if (!key && !(provider === 'custom' && loopback && !keyName)) fail('missing_api_key');
  const headers = { 'content-type': 'application/json' };
  if (provider === 'anthropic') Object.assign(headers, { 'x-api-key': key, 'anthropic-version': '2023-06-01' });
  else if (key) headers.authorization = `Bearer ${key}`;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel, { once: true });
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(cancel, config.timeoutMs);
  try {
    const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(apiRequest(provider, model, system, input)),
      redirect: 'error', signal: controller.signal });
    if (!response.ok) { await response.body?.cancel(); fail(`http_${response.status}`); }
    let bytes = 0, chunks = [];
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > MAX_RESPONSE) { controller.abort(); fail('response_too_large'); }
      chunks.push(chunk);
    }
    let frame; try { frame = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('invalid_response'); }
    return parseAPIOutput(provider, frame, model);
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    fail(controller.signal.aborted ? (signal?.aborted ? 'cancelled' : 'timeout') : 'network_failed');
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', cancel); }
}

export function validateText(result, original) {
  if (typeof result !== 'string' || !result.trim() || result.length > Math.max(original.length * 3, original.length + 40) ||
      /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/u.test(result) || (result.trim().startsWith('```') && !original.trim().startsWith('```'))) fail('invalid_cleaned_text');
  return result;
}

export async function cleanup(original, rawConfig = {}, { mode = 'prose', env = process.env, signal, diagnose = () => {} } = {}) {
  try {
    if (typeof original !== 'string') fail('invalid_input');
    if (!original.trim()) return original;
    if (Buffer.byteLength(original) > MAX_INPUT) fail('input_too_large');
    if (!['prose', 'strict'].includes(mode)) fail('invalid_mode');
    const config = parseConfig(rawConfig), selected = await select(config, env);
    if (selected.provider === 'none') return original;
    if (signal?.aborted) fail('cancelled');
    const system = await readFile(path.join(ROOT, 'prompts', `${mode}.txt`), 'utf8');
    const input = JSON.stringify({ transcript: original, vocabulary: config.vocabulary });
    let result;
    if (selected.launch) {
      const scratch = await mkdtemp(path.join(tmpdir(), 'sona-cleanup-'));
      try {
        if (selected.provider === 'gemini-cli') {
          const deadline = Date.now() + config.timeoutMs;
          let prepared;
          try { prepared = await prepareGemini(selected.launch, selected.model, scratch, system, env); }
          catch (error) { throw new BridgeError(error.code?.startsWith('gemini_') ? error.code : 'gemini_prepare_failed'); }
          const remaining = deadline - Date.now();
          if (remaining <= 0) fail('timeout');
          const output = await runProcess(prepared.launch, prepared.args, geminiInput(input),
            { env: prepared.env, cwd: scratch, signal, timeoutMs: remaining });
          if (await readFile(path.join(scratch, 'guard-applied'), 'utf8').catch(() => '') !== 'verified') fail('gemini_guard_not_applied');
          try { result = parseGeminiOutput(output, selected.model); }
          catch (error) { throw new BridgeError(error.code ?? 'invalid_response'); }
        } else {
          result = parseCLIOutput(selected.provider, await runProcess(selected.launch,
            cliArguments(selected.provider, selected.model, mode, system, scratch), input,
            { env, cwd: scratch, signal, timeoutMs: config.timeoutMs }));
        }
      } finally {
        // Only this invocation's newly created scratch directory is removed.
        await rm(scratch, { recursive: true, force: true }).catch(() => {});
      }
    } else result = await runAPI(selected.provider, selected.model, config, system, input, env, signal);
    return validateText(result, original);
  } catch (error) {
    diagnose(error instanceof BridgeError ? error.code : 'bridge_failed');
    return original;
  }
}

export async function doctor(rawConfig = {}, env = process.env) {
  const config = parseConfig(rawConfig);
  const providers = await Promise.all(Object.entries(PROVIDERS).map(async ([id, value]) => {
    const launch = value.transport === 'cli' ? await resolveCLI(id, config.provider === id ? config : {}, env) : null;
    let version, compatibilityReason;
    if (id === 'gemini-cli' && launch) {
      try { version = await geminiVersion(launch); } catch (error) { compatibilityReason = error.code; }
    }
    return {
    id, transport: value.transport === 'cli' ? 'CLI account' : 'API (provider billing may apply)',
    economyModel: value.model ?? null,
    available: value.transport === 'cli' ? Boolean(launch) && !compatibilityReason :
      Boolean(env[config.provider === id ? config.apiKeyEnv ?? value.apiKeyEnv : value.apiKeyEnv]),
    authenticationTested: false,
    ...(id === 'gemini-cli' ? { installed: Boolean(launch), requiredVersion: GEMINI_VERSION, version, compatibilityReason } : {}),
  }; }));
  return { nodeVersion: process.versions.node, supportedNode: Number(process.versions.node.split('.')[0]) >= 20,
    configuredProvider: config.provider, configuredModel: config.model, timeoutMs: config.timeoutMs,
    autoOrder: ['claude', 'codex'], providers, notes: [
      'Read-only local availability check. No authentication or model request was made.',
      'gemini-cli explicitly reuses an existing Google OAuth login on the reviewed CLI version; Gemini may retain local session history.',
      'gemini, grok, Kimi, and OpenCode remain explicit API adapters. Grok CLI integration is not implemented.',
      'No automatic API selection or fallback to another model/provider. Plain text survives all failures.',
    ] };
}
