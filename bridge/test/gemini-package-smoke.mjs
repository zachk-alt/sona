// Opt-in startup test against an already staged published 0.58.0 package.
// Uses a newly created empty HOME. No existing account, login or model call.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { prepareGemini, restrictedSettings, GEMINI_MODEL } from '../gemini-cli.mjs';
import { assertGeminiConfig, installGeminiGuard } from '../gemini-launch.mjs';
import { runProcess } from '../cleanup.mjs';

const entry = process.argv[2];
if (!entry || !path.isAbsolute(entry)) throw new Error('Supply an absolute path to the published bundle/gemini.js');
const scratch = await mkdtemp(path.join(tmpdir(), 'sona-gemini-package-smoke-'));
try {
  const home = path.join(scratch, 'home'); await mkdir(home);
  const env = { PATH: process.env.PATH, HOME: home, USERPROFILE: home,
    SystemRoot: process.env.SystemRoot, TMPDIR: scratch, TEMP: scratch, TMP: scratch,
    GEMINI_CLI_SYSTEM_SETTINGS_PATH: path.join(scratch, 'absent-system.json'),
    GEMINI_CLI_SYSTEM_DEFAULTS_PATH: path.join(scratch, 'absent-defaults.json') };
  const prepared = await prepareGemini({ command: process.execPath, prefix: [entry] },
    GEMINI_MODEL, scratch, 'Return the input transcript unchanged.', env);
  const started = performance.now();
  await assert.rejects(runProcess(prepared.launch, prepared.args, '{"transcript":"Hello."}',
    { env: prepared.env, cwd: scratch, timeoutMs: 10000 }), { code: 'cli_failed' });
  assert.equal(await readFile(path.join(scratch, 'guard-auth-checked'), 'utf8'), 'verified');
  assert.equal(await readFile(path.join(scratch, 'guard-applied'), 'utf8').catch(() => null), null);
  const startupMs = performance.now() - started;

  process.env.HOME = home; process.env.USERPROFILE = home;
  const { Config } = await import(pathToFileURL(path.join(path.dirname(entry), 'dist-LTIGO7GG.js')).href);
  const restrictions = restrictedSettings(GEMINI_MODEL, 'empty.context.md');
  const config = new Config({ sessionId: '00000000-0000-4000-8000-000000000001',
    targetDir: scratch, cwd: scratch, model: GEMINI_MODEL, debugMode: false,
    coreTools: [], enableHooks: false, skillsSupport: false, enableAgents: false,
    includeDirectories: [], memoryBoundaryMarkers: [], includeDirectoryTree: false,
    maxAttempts: 1, maxSessionTurns: 1, plan: false, billing: { overageStrategy: 'never' },
    dynamicModelConfiguration: true, modelConfigServiceConfig: restrictions.modelConfigs,
    experimentalGemma: false, experimentalAutoMemory: false, extensionLoader: { getExtensions: () => [] } });
  assertGeminiConfig(config); installGeminiGuard(Config);
  await assert.rejects(config.refreshAuth('gemini-api-key'), /gemini_auth_policy_conflict/u);
  assert.equal((await config.createToolRegistry()).getAllTools().length, 0);
  console.log(JSON.stringify({ packageVersion: '0.58.0', nodeVersion: process.versions.node,
    noAccountStartupMs: Math.round(startupMs), actualConfigPassed: true, actualTools: 0,
    apiAuthRejected: true, accountUsed: false }));
} finally { await rm(scratch, { recursive: true, force: true }); }
