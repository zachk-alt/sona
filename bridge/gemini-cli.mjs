import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Audited against the exact stable source, not a permissive version range.
export const GEMINI_VERSION = '0.58.0';
export const GEMINI_MODEL = 'gemini-3.1-flash-lite';
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const fail = (code) => { const error = new Error(code); error.code = code; throw error; };

// Gemini settings permit comments. Preserve comment-like text inside JSON strings.
export function parseSettings(text) {
  let result = '', quoted = false, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], next = text[i + 1];
    if (quoted) {
      result += c;
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') quoted = false;
    } else if (c === '"') { quoted = true; result += c; }
    else if (c === '/' && next === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      result += '\n';
    } else if (c === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++;
      if (i >= text.length) fail('gemini_settings_invalid');
      i++; result += ' ';
    } else result += c;
  }
  try { const value = JSON.parse(result); if (object(value)) return value; } catch {}
  fail('gemini_settings_invalid');
}

async function settingsFile(file) {
  try {
    const bytes = await readFile(file);
    if (bytes.length > 1024 * 1024) fail('gemini_settings_invalid');
    return parseSettings(bytes.toString('utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    fail('gemini_settings_invalid');
  }
}

export async function geminiVersion(launch) {
  if (Number(process.versions.node.split('.')[0]) < 24) fail('gemini_node_unsupported');
  let directory;
  try { directory = path.dirname(await realpath(launch.prefix[0] ?? launch.command)); }
  catch { fail('gemini_version_unverified'); }
  for (let i = 0; i < 7; i++) {
    try {
      const info = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
      if (info.name === '@google/gemini-cli') {
        if (info.version !== GEMINI_VERSION) fail('gemini_version_unsupported');
        return info.version;
      }
    } catch (error) {
      if (error.code === 'gemini_version_unsupported') throw error;
    }
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  fail('gemini_version_unverified');
}

export function restrictedSettings(model, contextName) {
  const kinds = ['terminal', 'transient', 'not_found', 'unknown'];
  const chain = [{ model, isLastResort: true, maxAttempts: 1,
    actions: Object.fromEntries(kinds.map((key) => [key, 'prompt'])),
    stateTransitions: Object.fromEntries(kinds.map((key) => [key, 'terminal'])) }];
  return {
    tools: { core: [], discoveryCommand: '', callCommand: '' },
    hooksConfig: { enabled: false }, skills: { enabled: false }, ide: { enabled: false },
    context: { fileName: contextName, includeDirectoryTree: false, includeDirectories: [],
      loadMemoryFromIncludeDirectories: false, memoryBoundaryMarkers: [], discoveryMaxDirs: 0 },
    security: { auth: { selectedType: 'oauth-personal', useExternal: false } },
    telemetry: { enabled: false, logPrompts: false }, billing: { overageStrategy: 'never' },
    general: { maxAttempts: 1, plan: { enabled: false, modelRouting: false }, topicUpdateNarration: false },
    advanced: { autoConfigureMemory: false },
    model: { name: model, maxSessionTurns: 1, skipNextSpeakerCheck: true, disableLoopDetection: true },
    experimental: { enableAgents: false, autoMemory: false, gemma: false, modelSteering: false,
      dynamicModelConfiguration: true, gemmaModelRouter: { enabled: false, autoStartServer: false } },
    modelConfigs: {
      modelIdResolutions: { [model]: { default: model, contexts: [] } },
      modelChains: Object.fromEntries(['lite', 'default', 'preview', 'auto-default', 'auto-preview'].map((key) => [key, chain])),
      overrides: [], customOverrides: [],
    },
  };
}

// System overrides still load in the CLI. Conflicting restrictions fail closed,
// rather than replacing or weakening enterprise policy. No settings are logged.
export function checkSettingsLayers(layers, restrictions) {
  const system = layers.at(-1);
  for (const layer of layers) {
    if (!object(layer)) fail('gemini_settings_invalid');
    if (layer.context?.includeDirectories?.length) fail('gemini_context_conflict');
    if (layer.modelConfigs && Object.keys(layer.modelConfigs).length) fail('gemini_model_config_conflict');
    if (layer.tools?.sandbox) fail('gemini_sandbox_config_conflict');
    if (layer.security?.auth?.enforcedType && layer.security.auth.enforcedType !== 'oauth-personal') fail('gemini_auth_policy_conflict');
  }
  const compare = (required, actual) => {
    if (actual === undefined) return;
    if (object(required) && object(actual)) {
      for (const key of Object.keys(required)) compare(required[key], actual[key]);
    } else if (JSON.stringify(required) !== JSON.stringify(actual)) fail('gemini_managed_settings_conflict');
  };
  compare(restrictions, system);
}

export async function prepareGemini(launch, model, scratch, systemPrompt, env) {
  await geminiVersion(launch);
  // Arbitrary aliases could re-enable routing. More pins require a source audit.
  if (model !== GEMINI_MODEL) fail('gemini_model_unsupported');
  if (env.GEMINI_CLI_TRUST_WORKSPACE === 'false') fail('gemini_workspace_untrusted');
  if (env.GEMINI_SANDBOX) fail('gemini_sandbox_config_conflict');
  const systemPath = env.GEMINI_CLI_SYSTEM_SETTINGS_PATH ?? (process.platform === 'darwin'
    ? '/Library/Application Support/GeminiCli/settings.json' : process.platform === 'win32'
      ? 'C:\\ProgramData\\gemini-cli\\settings.json' : '/etc/gemini-cli/settings.json');
  const defaultsPath = env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH ?? path.join(path.dirname(systemPath), 'system-defaults.json');
  const home = env.GEMINI_CLI_HOME || env.HOME || env.USERPROFILE || homedir();
  const restrictions = restrictedSettings(model, path.basename(scratch) + '.context.md');
  const layers = await Promise.all([defaultsPath, path.join(home, '.gemini', 'settings.json'), systemPath].map(settingsFile));
  checkSettingsLayers(layers, restrictions);
  const folder = path.join(scratch, '.gemini');
  await mkdir(folder, { mode: 0o700 });
  await writeFile(path.join(folder, 'settings.json'), JSON.stringify(restrictions), { mode: 0o600 });
  // Stop Gemini's upward/global dotenv search at this empty file.
  await writeFile(path.join(folder, '.env'), '', { mode: 0o600 });
  const promptPath = path.join(scratch, 'system.md');
  await writeFile(promptPath, systemPrompt, { mode: 0o600 });
  const policyPath = path.join(scratch, 'deny-tools.toml');
  await writeFile(policyPath, '[[rule]]\ntoolName = "*"\ndecision = "deny"\npriority = 999\n', { mode: 0o600 });
  const childEnv = { ...env, NO_BROWSER: '1', GEMINI_CLI_TRUST_WORKSPACE: 'true', GEMINI_SYSTEM_MD: promptPath,
    GEMINI_CLI_NO_RELAUNCH: '1' };
  for (const name of Object.keys(childEnv)) {
    if (/^(?:GEMINI_TELEMETRY_|GEMINI_WRITE_SYSTEM_MD|GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_GENAI_USE_VERTEXAI|GOOGLE_APPLICATION_CREDENTIALS|GEMINI_CLI_IDE_|GEMINI_CLI_USE_COMPUTE_ADC|NODE_OPTIONS$)/u.test(name)) delete childEnv[name];
  }
  const entry = await realpath(launch.prefix[0] ?? launch.command);
  return { env: childEnv,
    launch: { command: process.execPath, prefix: [path.join(path.dirname(fileURLToPath(import.meta.url)), 'gemini-launch.mjs'), entry] },
    args: ['--output-format', 'json', '--model', model, '--extensions', 'none',
      '--approval-mode', 'default', '--policy', policyPath] };
}

export function geminiInput(json) {
  // Headless Gemini expands @file before the model and bypasses its tool registry.
  // A JSON envelope avoids slash commands, and Unicode escapes avoid @ expansion.
  return json.replaceAll('@', '\\u0040');
}

export function parseGeminiOutput(output, model) {
  let frame;
  try { frame = JSON.parse(output); } catch { fail('invalid_response'); }
  if (!object(frame) || frame.error != null || typeof frame.response !== 'string') fail('provider_error');
  if (frame.stats?.tools?.totalCalls !== 0 || Object.keys(frame.stats.tools.byName ?? {}).length) fail('unexpected_tool_event');
  const models = frame.stats?.models;
  if (!object(models) || Object.keys(models).length !== 1 || !Object.hasOwn(models, model)) fail('model_changed');
  if (models[model]?.api?.totalErrors !== 0 || !(models[model]?.api?.totalRequests > 0)) fail('provider_error');
  return frame.response;
}
