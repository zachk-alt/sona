import { register } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
import { GEMINI_MODEL } from './gemini-cli.mjs';

// v0.58.0 ignores file-based admin settings. Inspect the actual Config after
// cached OAuth and remote admin policy have loaded, BEFORE initialize starts
// MCP servers, extension processes, hooks, skills or the model. Refuse conflicts;
// never rewrite managed settings or pretend their defaults disable tools.
export function assertGeminiConfig(config) {
  const empty = (value) => Array.isArray(value) && value.length === 0;
  const chain = config.modelConfigService.resolveChain('lite');
  if (!empty(config.getCoreTools()) || config.getEnableHooks() !== false ||
      config.isSkillsSupportEnabled() !== false || config.enableAgents !== false ||
      config.getToolDiscoveryCommand() || config.getToolCallCommand() || config.getMcpServerCommand() ||
      Object.keys(config.getMcpServers() ?? {}).length || config.getExtensions().some((item) => item.isActive) ||
      config.getModel() !== GEMINI_MODEL || config.getBillingSettings().overageStrategy !== 'never' ||
      config.getExperimentalDynamicModelConfiguration() !== true ||
      !Array.isArray(chain) || chain.length !== 1 || chain[0].model !== GEMINI_MODEL || !chain[0].isLastResort ||
      config.getMaxAttempts() !== 1 || config.getMaxSessionTurns() !== 1 ||
      config.getIncludeDirectoryTree() !== false || !empty(config.getMemoryBoundaryMarkers()) ||
      !empty(config.pendingIncludeDirectories) || config.isPlanEnabled() !== false) {
    throw new Error('gemini_effective_config_conflict');
  }
}

export function installGeminiGuard(Config) {
  const proto = Config.prototype;
  const initialize = proto.initialize, refreshAuth = proto.refreshAuth, registry = proto.createToolRegistry;
  if (![initialize, refreshAuth, registry].every((item) => typeof item === 'function')) throw new Error('gemini_interface_changed');
  proto.refreshAuth = async function (authType, ...rest) {
    if (authType !== 'oauth-personal') throw new Error('gemini_auth_policy_conflict');
    assertGeminiConfig(this);
    await writeFile(path.join(process.cwd(), 'guard-auth-checked'), 'verified', { mode: 0o600 });
    return refreshAuth.call(this, authType, ...rest);
  };
  proto.initialize = async function (...rest) {
    assertGeminiConfig(this);
    await writeFile(path.join(process.cwd(), 'guard-applied'), 'verified', { mode: 0o600 });
    return initialize.apply(this, rest);
  };
  proto.createToolRegistry = async function (...rest) {
    assertGeminiConfig(this);
    const result = await registry.apply(this, rest);
    if (result.getAllTools().length !== 0) throw new Error('gemini_unexpected_tools');
    return result;
  };
}

async function main() {
  const entry = process.argv[2], args = process.argv.slice(3);
  if (!entry || !path.isAbsolute(entry)) throw new Error('gemini_entry_invalid');
  globalThis[Symbol.for('sona.gemini.installGuard')] = installGeminiGuard;
  register('./gemini-loader.mjs', import.meta.url, { data: { bundleRoot: path.dirname(entry) } });
  process.argv = [process.execPath, entry, ...args];
  await import(pathToFileURL(entry).href);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { process.stderr.write('gemini_guard_failed\n'); process.exitCode = 1; });
}
