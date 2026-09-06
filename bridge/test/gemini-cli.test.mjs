import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { cleanup, doctor } from '../cleanup.mjs';
import { GEMINI_MODEL, GEMINI_VERSION, checkSettingsLayers, geminiInput, parseGeminiOutput, parseSettings, restrictedSettings } from '../gemini-cli.mjs';

const raw = 'um hello world';
const settings = restrictedSettings(GEMINI_MODEL, 'empty.context.md');

test('Gemini settings comments, escaped at-signs and fixed model chain', () => {
  assert.deepEqual(parseSettings('{/*comment*/ "url":"https://example.invalid/a//b", // end\n"ok":true}'), { url: 'https://example.invalid/a//b', ok: true });
  assert.throws(() => parseSettings('{/*unfinished'));
  const original = '/run @private.txt user@example.invalid "C:\\file"';
  const input = geminiInput(JSON.stringify({ transcript: original, vocabulary: ['@tag'] }));
  assert(input.startsWith('{') && !input.includes('@'));
  assert.equal(JSON.parse(input).transcript, original);
  assert.equal(JSON.parse(input).vocabulary[0], '@tag');
  assert.deepEqual(settings.tools.core, []);
  assert.equal(settings.experimental.dynamicModelConfiguration, true);
  for (const chain of Object.values(settings.modelConfigs.modelChains)) {
    assert.equal(chain.length, 1); assert.equal(chain[0].model, GEMINI_MODEL);
    assert.equal(chain[0].isLastResort, true); assert.equal(chain[0].maxAttempts, 1);
    assert(Object.values(chain[0].stateTransitions).every((value) => value === 'terminal'));
  }
});

test('Gemini preserves managed restrictions and rejects conflicting inherited context, models and sandbox', () => {
  checkSettingsLayers([{ hooksConfig: { enabled: true } }, {}, { security: { disableYoloMode: true } }], settings);
  for (const conflict of [ { tools: { core: ['run_shell_command'] } }, { hooksConfig: { enabled: true } },
    { billing: { overageStrategy: 'always' } }, { experimental: { enableAgents: true } },
    { context: { includeDirectories: ['extra-directory'] } }, { modelConfigs: { customAliases: {} } },
    { security: { auth: { enforcedType: 'gemini-api-key' } } }, { tools: { sandbox: true } } ]) {
    assert.throws(() => checkSettingsLayers([{}, {}, conflict], settings));
  }
});

const coreSource = `
import fs from 'node:fs/promises';
import path from 'node:path';
export class Config {
 constructor(settings) {
  this.s=settings; this.enableAgents=settings.experimental.enableAgents; this.pendingIncludeDirectories=[];
  this.modelConfigService={resolveChain:()=>settings.modelConfigs.modelChains.lite};
 }
 getCoreTools(){return this.s.tools.core}
 getEnableHooks(){return process.env.SONA_GEMINI_CASE==='remote-hook' || this.s.hooksConfig.enabled}
 isSkillsSupportEnabled(){return this.s.skills.enabled}
 getToolDiscoveryCommand(){return this.s.tools.discoveryCommand}
 getToolCallCommand(){return this.s.tools.callCommand}
 getMcpServerCommand(){return undefined}
 getMcpServers(){return process.env.SONA_GEMINI_CASE==='remote-mcp'?{required:{command:'must-never-run'}}:{}}
 getExtensions(){return process.env.SONA_GEMINI_CASE==='extension'?[{isActive:true}]:[]}
 getModel(){return this.s.model.name}
 getBillingSettings(){return this.s.billing}
 getExperimentalDynamicModelConfiguration(){return this.s.experimental.dynamicModelConfiguration}
 getMaxAttempts(){return this.s.general.maxAttempts}
 getMaxSessionTurns(){return this.s.model.maxSessionTurns}
 getIncludeDirectoryTree(){return this.s.context.includeDirectoryTree}
 getMemoryBoundaryMarkers(){return this.s.context.memoryBoundaryMarkers}
 isPlanEnabled(){return this.s.general.plan.enabled}
 async refreshAuth(){return undefined}
 async createToolRegistry(){return {getAllTools:()=>process.env.SONA_GEMINI_CASE==='registry-tool'?[{}]:[]}}
 async initialize(){await this.createToolRegistry(); await fs.writeFile(process.env.SONA_GEMINI_MARKER,'initialized')}
}
`;

const entrySource = `
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import {Config} from '@google/gemini-cli-core';
globalThis[Symbol.for('sona.gemini.installGuard')](Config);
let input='';for await(const chunk of process.stdin) input+=chunk;
assert(input.startsWith('{')&&!input.includes('@'));
assert(!process.argv.join(' ').includes('transcript'));
assert.equal(process.env.NO_BROWSER,'1');
assert.equal(process.env.GEMINI_CLI_NO_RELAUNCH,'1');
assert.equal(process.env.GEMINI_TELEMETRY_ENABLED,undefined);
assert.equal(process.env.GEMINI_TELEMETRY_LOG_PROMPTS,undefined);
assert.equal(process.env.GEMINI_API_KEY,undefined);
assert.equal(process.env.GEMINI_WRITE_SYSTEM_MD,undefined);
assert.equal(await fs.readFile('.gemini/.env','utf8'),'');
assert.equal(process.env.HOME,process.env.SONA_GEMINI_HOME);
const settings=JSON.parse(await fs.readFile('.gemini/settings.json','utf8'));
assert.equal(process.argv[process.argv.indexOf('--extensions')+1],'none');
assert.equal(process.argv[process.argv.indexOf('--model')+1],settings.model.name);
const cfg=new Config(settings), kind=process.env.SONA_GEMINI_CASE;
await cfg.refreshAuth(kind==='auth-change'?'gemini-api-key':'oauth-personal');
await cfg.initialize();
if(kind==='silent'){setInterval(()=>{},1000)}else{
 const frame={session_id:'synthetic',response:kind==='echo'?JSON.parse(input).transcript:'Hello, world.',
 stats:{models:{[settings.model.name]:{api:{totalRequests:1,totalErrors:0}}},tools:{totalCalls:0,byName:{}}}};
 if(kind==='error') frame.error={type:'AUTH',message:'fixture diagnostic must not be printed'};
 if(kind==='empty') frame.response='';
 if(kind==='changed-model') frame.stats.models={'larger-model':{api:{totalRequests:1,totalErrors:0}}};
 if(kind==='tool-event') frame.stats.tools.totalCalls=1;
 if(kind==='api-error') frame.stats.models[settings.model.name].api.totalErrors=1;
 if(kind==='malformed') process.stdout.write('{broken');else process.stdout.write(JSON.stringify(frame));
 if(kind==='nonzero') process.exitCode=1;
 if(kind==='result-then-hang') setInterval(()=>{},1000);
}
`;

test('Gemini complete subprocess lifecycle uses cached-auth route and refuses every unsafe/error result', async (context) => {
  const folder = await mkdtemp(path.join(tmpdir(), 'sona-gemini-test-'));
  try {
    const cli = path.join(folder, 'node_modules', '@google', 'gemini-cli');
    const core = path.join(cli, 'node_modules', '@google', 'gemini-cli-core');
    const entry = path.join(cli, 'dist', 'index.js');
    await mkdir(path.dirname(entry), { recursive: true }); await mkdir(core, { recursive: true });
    const metadata = { name: '@google/gemini-cli', version: GEMINI_VERSION, type: 'module' };
    await writeFile(path.join(cli, 'package.json'), JSON.stringify(metadata));
    await writeFile(path.join(core, 'package.json'), JSON.stringify({ name: '@google/gemini-cli-core', version: GEMINI_VERSION, type: 'module', exports: './index.js' }));
    await writeFile(path.join(core, 'index.js'), coreSource); await writeFile(entry, entrySource);
    const home = path.join(folder, 'home'), marker = path.join(folder, 'initialization');
    await mkdir(home); const systemPath = path.join(folder, 'system.json');
    const cfg = { ai: { provider: 'gemini-cli', executable: process.execPath, args: [entry], timeoutMs: 450 } };
    const env = { ...process.env, HOME: home, USERPROFILE: home, SONA_GEMINI_HOME: home,
      GEMINI_CLI_SYSTEM_SETTINGS_PATH: systemPath, GEMINI_CLI_SYSTEM_DEFAULTS_PATH: path.join(folder, 'defaults.json'),
      SONA_GEMINI_MARKER: marker, GEMINI_API_KEY: 'synthetic-only', GEMINI_WRITE_SYSTEM_MD: 'must-not-write',
      GEMINI_TELEMETRY_ENABLED: 'true', GEMINI_TELEMETRY_LOG_PROMPTS: 'true' };
    for (const kind of ['success', 'echo', 'remote-hook', 'remote-mcp', 'extension', 'registry-tool', 'auth-change',
      'silent', 'result-then-hang', 'error', 'empty', 'changed-model', 'tool-event', 'api-error', 'malformed', 'nonzero']) {
      await context.test(kind, async () => {
        await rm(marker, { force: true });
        const diagnostics = [], started = performance.now();
        const original = kind === 'echo' ? '/execute @private.txt user@example.invalid' : raw;
        const result = await cleanup(original, cfg, { env: { ...env, SONA_GEMINI_CASE: kind }, diagnose: (value) => diagnostics.push(value) });
        assert.equal(result, kind === 'success' ? 'Hello, world.' : original);
        if (['remote-hook', 'remote-mcp', 'extension', 'registry-tool', 'auth-change'].includes(kind)) {
          assert.equal(await readFile(marker, 'utf8').catch(() => null), null, 'Unsafe initialization must not run');
        }
        assert.equal(diagnostics.length, ['success', 'echo'].includes(kind) ? 0 : 1);
        assert(performance.now() - started < 1600);
      });
    }
    await context.test('unknown version launches nothing and doctor reports incompatibility', async () => {
      await writeFile(path.join(cli, 'package.json'), JSON.stringify({ ...metadata, version: '0.59.0' }));
      const diagnostics=[];
      assert.equal(await cleanup(raw, cfg, { env, diagnose:(v)=>diagnostics.push(v) }), raw);
      assert.deepEqual(diagnostics,['gemini_version_unsupported']);
      const report=await doctor(cfg,env), row=report.providers.find((v)=>v.id==='gemini-cli');
      assert.equal(row.available,false);assert.equal(row.installed,true);assert.equal(row.authenticationTested,false);
    });
    await context.test('managed settings are not overwritten', async () => {
      await writeFile(path.join(cli, 'package.json'), JSON.stringify(metadata));
      const content='{"hooksConfig":{"enabled":true}}';await writeFile(systemPath,content);
      const diagnostics=[];assert.equal(await cleanup(raw,cfg,{env,diagnose:(v)=>diagnostics.push(v)}),raw);
      assert.deepEqual(diagnostics,['gemini_managed_settings_conflict']);
      assert.equal(await readFile(systemPath,'utf8'),content);
    });
    await context.test('alternate Gemini home uses the same settings scope as the CLI', async () => {
      await rm(systemPath, { force: true });
      const alternate = path.join(folder, 'alternate'); await mkdir(path.join(alternate, '.gemini'), { recursive: true });
      await writeFile(path.join(alternate, '.gemini', 'settings.json'), '{"context":{"includeDirectories":["extra-context"]}}');
      const diagnostics=[];
      assert.equal(await cleanup(raw,cfg,{env:{...env,GEMINI_CLI_HOME:alternate},diagnose:(v)=>diagnostics.push(v)}),raw);
      assert.deepEqual(diagnostics,['gemini_context_conflict']);
    });
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('Gemini missing stats, unexpected calls and model changes cannot become pasted text', () => {
  for (const frame of [ { response: 'Hello.' }, { error: {}, response: 'Hello.' },
    { response: 'Hello.', stats: { tools: { totalCalls: 0 }, models: {} } } ]) {
    assert.throws(() => parseGeminiOutput(JSON.stringify(frame), GEMINI_MODEL));
  }
});
