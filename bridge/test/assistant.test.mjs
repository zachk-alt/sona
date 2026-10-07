import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { assistantSettings, normalizeModels, validateAssistantInput, assistantRequest, parseAssistantJSON, assistantPrompt } from '../assistant.mjs';
import { dispatchRequest } from '../operations.mjs';
import { claudeModels, codexModels, assistantEnvironment, claudeErrorReason } from '../assistant-transports.mjs';

const fixture = fileURLToPath(new URL('./fake-assistant-cli.mjs', import.meta.url));
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=';
const request = { version: 1, operation: 'assistant', intent: 'screen_ask', instruction: 'What is shown?', images: [{ mimeType: 'image/png', dataBase64: png }] };
async function run(t, change = {}, settings = {}, scenario = 'answer') {
  const dir = await mkdtemp(path.join(tmpdir(), 'sona-assistant-test-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const record = path.join(dir, 'calls.jsonl');
  const config = { ai: { provider: settings.provider ?? 'claude', model: 'economy', executable: process.execPath, args: [fixture] },
    assistant: { provider: 'inherit', model: 'default', effort: 'default', timeoutMs: 2000, ...settings } };
  // The fixture provider also describes the configured route.
  if (settings.provider) config.assistant.provider = 'inherit';
  const diagnostics = [];
  const result = await dispatchRequest({ ...request, ...change }, config, { env: { ...process.env, SONA_FAKE_CASE: scenario, SONA_FAKE_RECORD: record }, diagnose: (code) => diagnostics.push(code) });
  const calls = (await readFile(record, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse);
  return { result, calls, diagnostics };
}

const sdkErrors = [
  ['authentication_failed','authentication_failed'], ['oauth_org_not_allowed','provider_access_denied'],
  ['billing_error','billing_error'], ['rate_limit','rate_limited'], ['invalid_request','provider_request_rejected'],
  ['model_not_found','assistant_model_unavailable'], ['server_error','provider_unavailable'],
  ['max_output_tokens','incomplete_response'], ['unknown','provider_error'],
];
const apiErrors = [
  ['authentication_error','authentication_failed'], ['billing_error','billing_error'], ['permission_error','provider_access_denied'],
  ['not_found_error','provider_request_rejected'], ['invalid_request_error','provider_request_rejected'],
  ['request_too_large','provider_request_rejected'], ['rate_limit_error','rate_limited'], ['api_error','provider_unavailable'],
  ['timeout_error','timeout'], ['overloaded_error','provider_unavailable'],
];
test('Claude structured error classification uses only exact documented scalar or type fields', () => {
  for (const [code, reason] of sdkErrors) assert.equal(claudeErrorReason(code), reason);
  for (const [code, reason] of apiErrors) assert.equal(claudeErrorReason({ type: code, message: 'PRIVATE_PROVIDER_DIAGNOSTIC' }), reason);
  for (const value of [null, undefined, false, 404, [], 'PRIVATE_PROVIDER_DIAGNOSTIC', 'Authentication_failed',
    { message: 'authentication_failed' }, { code: 'model_not_found' }, { status: 404 }, { type: 'unknown', message: 'billing_error' },
    { type: { type: 'authentication_error' } }]) assert.equal(claudeErrorReason(value), 'provider_error');
  assert.notEqual(claudeErrorReason({ type: 'not_found_error' }), 'assistant_model_unavailable');
});
for (const [source, cases] of [['sdk', sdkErrors], ['api', apiErrors]]) {
  for (const [code, reason] of cases) test(`Claude ${source} structured ${code} returns only its safe reason after one generation`, async (t) => {
    const { result, calls, diagnostics } = await run(t, {}, {}, `${source}_error:${code}`);
    assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'error', reason });
    assert.deepEqual(diagnostics, [reason]);
    assert.equal(calls.filter((call) => call.generation).length, 1);
    assert(!JSON.stringify({ result, diagnostics }).includes('PRIVATE_PROVIDER_DIAGNOSTIC'));
  });
}
test('Claude tool denial takes priority over structured provider errors', async (t) => {
  for (const [scenario, reason] of [['structured_error_tool_priority','provider_tool_or_error'],
    ['structured_error_server_tool_priority','provider_tool_or_error'], ['structured_error_init_priority','provider_tools_enabled']]) {
    const { result, calls, diagnostics } = await run(t, {}, {}, scenario);
    assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'error', reason });
    assert.deepEqual(diagnostics, [reason]);
    assert.equal(calls.filter((call) => call.generation).length, 1);
  }
});
test('Claude private diagnostic text is neither classified nor returned, and partial output is rejected', async (t) => {
  for (const [scenario, reason] of [['structured_error_message_only','provider_error'], ['structured_error_unknown','provider_error'],
    ['structured_error_max_tokens','incomplete_response']]) {
    const { result, calls, diagnostics } = await run(t, {}, {}, scenario);
    assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'error', reason });
    assert.deepEqual(diagnostics, [reason]);
    assert.equal(calls.filter((call) => call.generation).length, 1);
    assert(!JSON.stringify({ result, diagnostics }).includes('PRIVATE_PROVIDER_DIAGNOSTIC'));
  }
});
test('Claude assistant-profile rewrite structured failures never supply a replacement', async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sona-rewrite-structured-error-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const record = path.join(dir, 'calls.jsonl'), diagnostics = [];
  const result = await dispatchRequest({ version:1, operation:'rewrite', profile:'assistant', selection:'  ORIGINAL SELECTION  ', instruction:'Make it short.' },
    { ai:{ provider:'claude', executable:process.execPath, args:[fixture] } },
    { env:{ ...process.env, SONA_FAKE_CASE:'sdk_error:authentication_failed', SONA_FAKE_RECORD:record }, diagnose:(code) => diagnostics.push(code) });
  const calls = (await readFile(record, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(result, { version:1, operation:'rewrite', status:'error', reason:'authentication_failed' });
  assert.deepEqual(diagnostics, ['authentication_failed']);
  assert.equal(calls.filter((call) => call.generation).length, 1);
});
test('Claude structured catalog errors stop before generation and expose no diagnostic body', async (t) => {
  const { result, calls, diagnostics } = await run(t, {}, {}, 'catalog_structured_error');
  assert.deepEqual(result, { version:1, operation:'assistant', status:'error', reason:'authentication_failed' });
  assert.deepEqual(diagnostics, ['authentication_failed']);
  assert.equal(calls.filter((call) => call.generation).length, 0);
  assert(!JSON.stringify({ result, diagnostics }).includes('PRIVATE_PROVIDER_DIAGNOSTIC'));
});
test('Claude malformed assistant content cannot be laundered by a later success result', async (t) => {
  for (const scenario of ['malformed_assistant_content_object', 'malformed_assistant_content_string']) {
    const { result, calls, diagnostics } = await run(t, {}, {}, scenario);
    assert.deepEqual(result, { version:1, operation:'assistant', status:'error', reason:'invalid_response' });
    assert.deepEqual(diagnostics, ['invalid_response']);
    assert.equal(calls.filter((call) => call.generation).length, 1);
  }
});

test('assistant defaults are separate; bad assistant settings cannot change ordinary dictate', async () => {
  assert.equal(assistantSettings({}).timeoutMs, 120000);
  assert.throws(() => assistantSettings({ assistant: { timeoutMs: 180001 } }));
  const result = await dispatchRequest({ version: 1, operation: 'dictate', transcript: 'raw', mode: 'prose', cleanupEnabled: false }, { ai: { provider: 'none' }, assistant: { model: null } });
  assert.equal(result.text, 'raw'); assert.equal(result.status, 'ok');
});
test('dictate and snippet assist reject assistant overrides before any call', async () => {
  for (const operation of ['dictate', 'snippet_assist']) {
    const value = operation === 'dictate' ? { transcript: 'raw', mode: 'prose', cleanupEnabled: true } : { context: 'Supplied context' };
    const result = await dispatchRequest({ version: 1, operation, ...value, options: { model: 'expensive' } });
    assert.equal(result.status, operation === 'dictate' ? 'fallback' : 'error');
  }
});
test('image validation rejects paths, wrong MIME, malformed base64 and oversized history', () => {
  validateAssistantInput(request);
  for (const images of [[{ path: '/tmp/image.png' }], [{ mimeType: 'image/jpeg', dataBase64: png }], [{ mimeType: 'image/png', dataBase64: 'bad!' }]])
    assert.throws(() => validateAssistantInput({ ...request, images }));
  assert.throws(() => validateAssistantInput({ ...request, context: { apps: [{ id: 'app', label: 'One' }, { id: 'app', label: 'Two' }] } }));
  assert.throws(() => validateAssistantInput({ ...request, context: { apps: [{ id: 'app', label: ' ' }] } }));
  assert.throws(() => validateAssistantInput({ ...request, messages: Array(17).fill({ role: 'user', content: 'x' }) }));
  assert.throws(() => validateAssistantInput({ ...request, messages: [{ role: 'system', content: 'x' }] }));
  assert.throws(() => validateAssistantInput({ ...request, messages: Array(3).fill({ role: 'user', content: 'x'.repeat(16384) }) }));
});
test('actual catalog shape preserves text-only distinction and safe default effort', () => {
  const rows = normalizeModels('codex', [{ model: 'gpt-5.3-codex-spark', displayName: 'Spark', inputModalities: ['text'], supportedReasoningEfforts: [{ reasoningEffort: 'high' }], defaultReasoningEffort: 'high' }]);
  assert.deepEqual(rows[0].operations, ['edit_selection']);
});
test('Claude catalog exposes only model metadata and sends no user prompt', async (t) => {
  const models = await claudeModels({ command: process.execPath, prefix: [fixture] }, { env: process.env, timeoutMs: 2000 });
  assert.equal(models[0].resolvedModel, 'claude-opus-5'); assert.equal('account' in models[0], false);
});
test('Codex catalog uses no thread or turn', async () => {
  const models = await codexModels({ command: process.execPath, prefix: [fixture] }, { env: process.env, timeoutMs: 2000 });
  assert.equal(models[0].model, 'gpt-5.6-luna');
});
test('Claude screen request sends identical image bytes, one generation, and defaults to Haiku', async (t) => {
  const { result, calls } = await run(t);
  assert.equal(result.kind, 'answer'); assert.equal(result.status, 'ok');
  const turns = calls.filter((call) => call.generation); assert.equal(turns.length, 1);
  assert.deepEqual(turns[0].images, [png]);
  assert.equal(turns[0].args[turns[0].args.indexOf('--model') + 1], 'claude-haiku-4-5-20251001');
  assert(turns[0].args.includes('--no-session-persistence')); assert.equal(turns[0].args.includes('--bare'), false);
});
test('explicit saved model and effort persist into the sole generation', async (t) => {
  const { result, calls } = await run(t, {}, { model: 'claude-opus-5', effort: 'max' });
  assert.equal(result.status, 'ok'); const args = calls.find((call) => call.generation).args;
  assert.equal(args[args.indexOf('--effort') + 1], 'max');
});
test('both assistant transports receive concise follow-up guidance in their sole generation', async (t) => {
  const messages = [{ role: 'user', content: 'What is shown?' }, { role: 'assistant', content: 'A blue square.' }];
  const context = { appName: 'Synthetic Browser', windowTitle: 'Synthetic page' };
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    const { result, calls } = await run(t, { instruction: 'What color is it?', messages, context }, { provider });
    assert.equal(result.status, 'ok');
    const turns = calls.filter((call) => call.generation);
    assert.equal(turns.length, 1);
    const { args, payload } = turns[0];
    const system = provider === 'claude' ? args[args.indexOf('--system-prompt') + 1]
      : JSON.parse(args.find((arg) => arg.startsWith('developer_instructions=')).slice('developer_instructions='.length));
    assert.match(system, /1 to 3 short sentences or at most 3 terse bullets/);
    assert.match(system, /no more than 60 words/);
    assert.match(system, /address the new request without recapping/);
    assert.match(system, /explicitly requests detail.*complete content/s);
    assert.match(system, /current app identified by context.appName and context.windowTitle/);
    assert.match(system, /read-only screen assistant/);
    assert.match(system, /When asked to act, give brief practical instructions/);
    assert.match(system, /Provider-side tools are disabled/);
    assert.doesNotMatch(system, /propose ONE native action|blender_create|context.apps/);
    assert.deepEqual(payload.messages, messages);
    assert.deepEqual(payload.context, context);
    assert.equal(payload.instruction, 'What color is it?');
  }
});
test('a requested detailed answer and complete code are never cut to the default word target', async (t) => {
  const expected = Array.from({ length: 80 }, (_, index) => `Detail${index + 1}`).join(' ') + '\n\n```swift\nlet complete = true\n```';
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    const { result, calls } = await run(t, { instruction: 'Explain in detail and include the complete code.' }, { provider }, 'detailed_answer');
    assert.equal(result.status, 'ok');
    assert.equal(result.text, expected);
    assert.equal(calls.filter((call) => call.generation).length, 1);
  }
});
test('unsupported effort or model refuses without generation', async (t) => {
  for (const settings of [{ model: 'unknown' }, { effort: 'max' }]) {
    const { result, calls } = await run(t, {}, settings); assert.equal(result.status, 'error'); assert.equal(calls.filter((call) => call.generation).length, 0);
  }
});
test('selected rewrite assistant profile preserves outer whitespace without image or answer insertion', async (t) => {
  const { result, calls } = await run(t, { operation: 'rewrite', profile: 'assistant', selection: '  Original.\n', instruction: 'Rewrite', images: undefined, intent: undefined });
  // Undefined assistant fields still are keys, so construct the exact protocol separately.
  assert.equal(result.status, 'error'); assert.equal(calls.length, 0);
  const dir = await mkdtemp(path.join(tmpdir(), 'sona-rewrite-prompt-test-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const record = path.join(dir, 'calls.jsonl');
  const config = { ai: { provider: 'claude', executable: process.execPath, args: [fixture] } };
  const rewrite = await dispatchRequest({ version: 1, operation: 'rewrite', profile: 'assistant', selection: '  Original.\n', instruction: 'Rewrite' }, config,
    { env: { ...process.env, SONA_FAKE_RECORD: record } });
  assert.equal(rewrite.text, '  Rewritten selection.\n');
  const rewriteCalls = (await readFile(record, 'utf8')).trim().split('\n').map(JSON.parse).filter((call) => call.generation);
  assert.equal(rewriteCalls.length, 1);
  const args = rewriteCalls[0].args;
  const system = args[args.indexOf('--system-prompt') + 1];
  assert.match(system, /complete replacement TEXT ONLY/);
  assert.doesNotMatch(system, /60 words|short sentences|terse bullets/);
});
test('assistant errors never contain insertable text and failed outputs are not repaired', async (t) => {
  for (const scenario of ['fail', 'error', 'tools', 'malformed', 'result_fail', 'stream_error', 'result_error_field', 'result_errors', 'result_errors_shape', 'result_missing_flag', 'result_missing_turns', 'result_denials_shape']) {
    const { result, calls } = await run(t, {}, {}, scenario); assert.equal(result.status, 'error', scenario); assert.equal(result.text, undefined); assert.equal(calls.filter((call) => call.generation).length, 1);
  }
});
test('success-shaped Claude error envelopes never return a rewrite replacement', async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sona-rewrite-error-test-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const config = { ai: { provider: 'claude', executable: process.execPath, args: [fixture] } };
  const request = { version: 1, operation: 'rewrite', profile: 'assistant', selection: '  Keep the original.\n', instruction: 'Make this shorter.' };
  for (const scenario of ['result_error_field', 'result_errors', 'stream_error']) {
    const record = path.join(dir, scenario + '.jsonl');
    const result = await dispatchRequest(request, config, { env: { ...process.env, SONA_FAKE_CASE: scenario, SONA_FAKE_RECORD: record } });
    assert.equal(result.status, 'error'); assert.equal(result.operation, 'rewrite');
    assert.equal(Object.hasOwn(result, 'text'), false); assert.equal(request.selection, '  Keep the original.\n');
    const calls = (await readFile(record, 'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(calls.filter((call) => call.generation).length, 1);
  }
});
test('assistant timeout includes result-then-hang; no retry', async (t) => {
  const start = Date.now(); const { result, calls } = await run(t, {}, { timeoutMs: 250 }, 'result_hang');
  assert.equal(result.status, 'error'); assert.equal(result.reason, 'timeout'); assert.equal(calls.filter((call) => call.generation).length, 1); assert(Date.now() - start < 2000);
});
test('Codex screen input uses inherited descriptor with exact PNG bytes and isolated exec', async (t) => {
  if (process.platform === 'win32') return t.skip('Requires actual Windows named-pipe reader fixture');
  const { result, calls } = await run(t, {}, { provider: 'codex' });
  assert.equal(result.status, 'ok'); const generation = calls.find((call) => call.generation);
  assert.deepEqual(generation.images, [png]); assert(generation.args.includes('--ignore-user-config')); assert(generation.args.includes('--ephemeral'));
  assert.equal(generation.args[generation.args.indexOf('--image') + 1], '/dev/fd/3');
});
test('text-only Codex model refuses screenshot before generation', async (t) => {
  const { result, calls } = await run(t, {}, { provider: 'codex', model: 'gpt-5.3-codex-spark' });
  assert.equal(result.status, 'error'); assert.equal(result.reason, 'assistant_vision_unavailable'); assert.equal(calls.filter((call) => call.generation).length, 0);
});
test('temporary messages remain explicit context in the sole read-only request', async (t) => {
  const messages = [{ role: 'user', content: 'Explain the square' }, { role: 'assistant', content: 'It is blue.' }];
  const { result, calls } = await run(t, { messages });
  assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'ok', kind: 'answer', text: 'A synthetic blue square.' });
  assert.deepEqual(calls.find((call) => call.generation).payload.messages, messages);
  assert.equal(calls.filter((call) => call.generation).length, 1);
});
test('assistant environment clears inherited reasoning overrides without exposing credentials', () => {
  const env = assistantEnvironment({ MAX_THINKING_TOKENS: '0', CLAUDE_CODE_EFFORT_LEVEL: 'max', OTEL_LOGS_EXPORTER: 'x', KEEP: 'yes' });
  assert.equal(env.MAX_THINKING_TOKENS, undefined); assert.equal(env.CLAUDE_CODE_EFFORT_LEVEL, undefined); assert.equal(env.OTEL_LOGS_EXPORTER, undefined); assert.equal(env.KEEP, 'yes');
});
test('a current Codex catalog exposes Astra and all advertised efforts without a model-name filter', async () => {
  const models = await codexModels({ command: process.execPath, prefix: [fixture] }, { env: { ...process.env, SONA_FAKE_CASE: 'astra_catalog' }, timeoutMs: 2000 });
  const astra = normalizeModels('codex', models).find((model) => model.id === 'gpt-6-astra');
  assert.equal(astra?.label, 'GPT-6-Astra'); assert.equal(astra?.vision, true);
  assert.deepEqual(astra?.efforts, ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']);
  assert.deepEqual(astra?.operations, ['edit_selection', 'screen_ask']);
});
test('Astra is selected only explicitly; its catalog default cannot replace the economy choice', async (t) => {
  if (process.platform === 'win32') return t.skip('Requires actual Windows named-pipe reader fixture');
  for (const settings of [{ model: 'gpt-6-astra', effort: 'max' }, { model: 'default', effort: 'default' }]) {
    const { result, calls } = await run(t, {}, { provider: 'codex', ...settings }, 'astra_catalog');
    assert.equal(result.status, 'ok');
    const turns = calls.filter((call) => call.generation); assert.equal(turns.length, 1);
    const args = turns[0].args;
    assert.equal(args[args.indexOf('--model') + 1], settings.model === 'default' ? 'gpt-5.6-luna' : 'gpt-6-astra');
    assert(args.includes(`model_reasoning_effort="${settings.effort === 'default' ? 'low' : 'max'}"`));
    assert(args.includes('--ignore-user-config')); assert(args.includes('--ephemeral'));
  }
});
test('an older catalog missing Astra refuses it without substituting another model or generating', async (t) => {
  const { result, calls } = await run(t, {}, { provider: 'codex', model: 'gpt-6-astra', effort: 'max' });
  assert.equal(result.status, 'error'); assert.equal(result.reason, 'assistant_model_unavailable');
  assert.equal(calls.filter((call) => call.generation).length, 0);
});
async function npmNativeFixture(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'sona-assistant-npm-test-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const launcher = path.join(dir, 'bin', 'codex.js'), link = path.join(dir, 'codex');
  const target = process.platform === 'darwin' ? `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-apple-darwin`
    : `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-unknown-linux-musl`;
  const native = path.join(dir, 'vendor', target, 'bin', 'codex');
  await mkdir(path.dirname(launcher), { recursive: true }); await mkdir(path.dirname(native), { recursive: true });
  await writeFile(path.join(dir, 'package.json'), JSON.stringify({ type: 'module' }));
  await writeFile(launcher, '#!/usr/bin/env node\nthrow new Error("npm wrapper must not run for assistant");\n');
  await chmod(launcher, 0o755); await symlink(launcher, link);
  await writeFile(native, `#!${process.execPath}\n${await readFile(fixture, 'utf8')}`); await chmod(native, 0o755);
  return { dir, launcher, link };
}
test('Codex catalog resolves npm native binaries when the GUI PATH has no Node', async (t) => {
  if (process.platform === 'win32') return t.skip('The runnable native fixture uses a POSIX shebang');
  const { dir, launcher, link } = await npmNativeFixture(t);
  for (const [index, launch] of [{ command: link, prefix: [] }, { command: process.execPath, prefix: [launcher] }].entries()) {
    const record = path.join(dir, `calls-${index}.jsonl`);
    const models = await codexModels(launch, { env: { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      SONA_FAKE_CASE: 'astra_catalog', SONA_FAKE_RECORD: record }, timeoutMs: 2000 });
    assert(models.some((model) => model.model === 'gpt-6-astra'));
    const calls = (await readFile(record, 'utf8')).trim().split('\n').map(JSON.parse);
    assert.deepEqual(calls, [{ catalog: true, provider: 'codex' }]);
  }
});
test('Astra selected rewrite uses one isolated native call when the GUI PATH has no Node', async (t) => {
  if (process.platform === 'win32') return t.skip('The runnable native fixture uses a POSIX shebang');
  const { dir, link } = await npmNativeFixture(t);
  const record = path.join(dir, 'rewrite-calls.jsonl');
  const result = await dispatchRequest({ version: 1, operation: 'rewrite', profile: 'assistant',
    selection: '  Keep the complete selection.\n', instruction: 'Make this shorter.' }, {
    ai: { provider: 'codex', executable: link }, assistant: { provider: 'inherit', model: 'gpt-6-astra', effort: 'max' },
  }, { env: { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', SONA_FAKE_CASE: 'astra_catalog', SONA_FAKE_RECORD: record } });
  assert.equal(result.status, 'ok'); assert.equal(result.text, '  Rewritten selection.\n');
  const calls = (await readFile(record, 'utf8')).trim().split('\n').map(JSON.parse);
  const generations = calls.filter((call) => call.generation);
  assert.equal(calls.filter((call) => call.catalog).length, 1); assert.equal(generations.length, 1);
  const { args, payload, images } = generations[0];
  assert.equal(args[args.indexOf('--model') + 1], 'gpt-6-astra');
  assert(args.includes('model_reasoning_effort="max"'));
  for (const flag of ['--ignore-user-config', '--ignore-rules', '--ephemeral']) assert(args.includes(flag));
  assert.deepEqual(images, []); assert.equal(payload.selection, 'Keep the complete selection.');
  assert.equal(payload.instruction, 'Make this shorter.');
});
function assertReadOnlyCall(calls, provider, expected) {
  const turns = calls.filter((call) => call.generation);
  assert.equal(turns.length, 1);
  const { args, payload, images } = turns[0];
  assert.equal(payload.instruction, expected.instruction);
  assert.deepEqual(payload.messages, expected.messages);
  assert.deepEqual(payload.context, expected.context);
  assert.deepEqual(images, [png]);
  const system = provider === 'claude' ? args[args.indexOf('--system-prompt') + 1]
    : JSON.parse(args.find((arg) => arg.startsWith('developer_instructions=')).slice('developer_instructions='.length));
  assert.match(system, /read-only screen assistant/);
  assert.match(system, /cannot operate apps, move or click the cursor/);
  assert.match(system, /When asked to act, give brief practical instructions the user can follow instead/);
  assert.match(system, /Never propose an executable action, a Blender scene, or an artifact/);
  assert.match(system, /Provider-side tools are disabled/);
  assert.doesNotMatch(system, /propose ONE native action|blender_create|context.apps/);
  if (provider === 'claude') {
    assert.equal(args[args.indexOf('--tools') + 1], '');
    assert(args.includes('--strict-mcp-config')); assert(args.includes('--no-session-persistence'));
  } else {
    assert(args.includes('--ignore-user-config')); assert(args.includes('--ignore-rules')); assert(args.includes('--ephemeral'));
  }
}

test('Open Chrome and navigation requests receive guidance contracts on both isolated transports', async (t) => {
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    for (const [instruction, scenario, text] of [
      ['Open Chrome', 'open_chrome_guidance', 'Open Google Chrome from your Applications folder or search for it in your app launcher.'],
      ['Could you get me to that video page?', 'navigation_guidance', 'Choose Create, then Video in the visible navigation menu.'],
    ]) {
      const change = { instruction, context: { appName: 'Synthetic Browser' }, messages: [] };
      const { result, calls } = await run(t, change, { provider }, scenario);
      assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'ok', kind: 'answer', text });
      assertReadOnlyCall(calls, provider, change);
    }
  }
});

test('read-only follow-ups preserve conversation and current question without continuation actions', async (t) => {
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    const change = { instruction: 'Which visible control should I choose next?',
      context: { appName: 'Synthetic Browser', windowTitle: 'Synthetic page' },
      messages: [{ role: 'user', content: 'How do I create a video?' }, { role: 'assistant', content: 'Choose Create first.' }] };
    const { result, calls } = await run(t, change, { provider }, 'followup_guidance');
    assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'ok', kind: 'answer', text: 'Choose Video in the open Create menu.' });
    assertReadOnlyCall(calls, provider, change);
  }
});

test('retired creation intent and app inventory are refused before any provider launch', async (t) => {
  for (const change of [{ intent: 'blender_create', instruction: 'Make a cube in Blender' },
    { intent: 'actions' }, { context: { appName: 'Chrome', apps: [] } },
    { context: { apps: [{ id: 'com.google.Chrome', label: 'Chrome' }] } }, { actions: [] }]) {
    const { result, calls } = await run(t, change);
    assert.equal(result.status, 'error'); assert.equal(result.text, undefined);
    assert.equal(result.actions, undefined); assert.equal(result.artifacts, undefined);
    assert.deepEqual(calls, []);
  }
  // The exported request helper also validates before metadata, not just the CLI dispatcher.
  await assert.rejects(assistantRequest({ ...request, intent: 'blender_create' }, {}), { code: 'invalid_assistant_request' });
});

test('unsolicited and explicitly requested action or Blender envelopes are rejected completely without retry', async (t) => {
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    for (const instruction of ['What is shown?', 'Open Chrome', 'Create a cube in Blender']) {
      for (const scenario of ['actions', 'blender', 'wait_action', 'answer_actions', 'answer_scene', 'answer_artifacts']) {
        const { result, calls } = await run(t, { instruction }, { provider }, scenario);
        assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'error', reason: 'invalid_assistant_response' });
        assert.equal(calls.filter((call) => call.generation).length, 1);
        assert.equal(calls.filter((call) => call.catalog).length, 1);
      }
    }
  }
});

test('the prompt, catalog and schemas expose only read-only answers and selected rewrites', async () => {
  const prompt = await readFile(new URL('../prompts/assistant.txt', import.meta.url), 'utf8');
  assert.equal(prompt.trim().replace('${process.platform}', process.platform), assistantPrompt());
  const source = await readFile(new URL('../assistant.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /import\(['"]\.\/blender|createBlenderScene|validateActions/);
  const requests = JSON.parse(await readFile(new URL('../request.schema.json', import.meta.url), 'utf8'));
  const ask = requests.oneOf.find((row) => row.properties.operation.const === 'assistant');
  assert.deepEqual(ask.properties.intent, { const: 'screen_ask' });
  assert.deepEqual(Object.keys(ask.properties.context.properties).sort(), ['appName', 'windowTitle']);
  const results = JSON.parse(await readFile(new URL('../result.schema.json', import.meta.url), 'utf8'));
  const answers = results.oneOf.filter((row) => row.properties.operation.const === 'assistant');
  assert.equal(answers.length, 1); assert.equal(answers[0].properties.kind.const, 'answer');
  assert.equal(answers[0].additionalProperties, false);
  assert.deepEqual(Object.keys(answers[0].properties).sort(), ['kind', 'operation', 'status', 'text', 'version']);
  assert.equal(results.$defs, undefined);
});

test('assistant JSON accepts one complete outer fence without extracting, repairing or truncating content', () => {
  const object = { kind: 'answer', text: 'Literal {braces} and ``` inside the answer remain intact.' };
  const json = JSON.stringify(object);
  for (const output of [json, '\n ' + json + '\t', '```json\n' + json + '\n```',
    '```\n' + json + '\n```', ' \n```JSON\t\r\n' + json + '\r\n```\n ']) {
    assert.deepEqual(parseAssistantJSON(output), object);
  }
  const invalid = [
    'Here is the answer:\n```json\n' + json + '\n```',
    '```json\n' + json + '\n```\nMore explanation.',
    '```json\n' + json + '\n```\n```json\n' + json + '\n```',
    '```json\n' + json + '\n' + json + '\n```',
    json + '\n' + json, '```json\n' + json,
    '```json\n{"kind":"answer","text":\n```',
    '```javascript\n' + json + '\n```',
    '```json\n// Comment\n' + json + '\n```',
    '```json\n{"kind":"answer","text":"Text",}\n```',
    '```json\n\n```', '', undefined,
    ' '.repeat(1024 * 1024) + '```json\n' + json + '\n```',
  ];
  for (const output of invalid) assert.throws(() => parseAssistantJSON(output), { code: 'invalid_assistant_response' });
  assert.match(assistantPrompt(), /Return raw JSON without Markdown fences or surrounding prose/);
});

test('both isolated transports accept complete fenced answers in the sole generation', async (t) => {
  const change = { instruction: 'What is shown?', context: { appName: 'Synthetic Browser' }, messages: [] };
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    const { result, calls } = await run(t, change, { provider }, 'fenced_answer');
    assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'ok', kind: 'answer', text: 'A synthetic blue square.' });
    assertReadOnlyCall(calls, provider, change);
  }
});

test('fenced output never permits action, artifact, scene or other extra fields', async (t) => {
  for (const provider of ['claude', 'codex']) {
    if (provider === 'codex' && process.platform === 'win32') continue;
    for (const scenario of ['fenced_click', 'fenced_blender', 'fenced_answer_actions', 'fenced_answer_scene',
      'fenced_answer_artifacts', 'fenced_extra_response_field', 'fenced_array_response']) {
      const change = { instruction: 'Explain the visible control.', context: { appName: 'Synthetic Browser' }, messages: [] };
      const { result, calls } = await run(t, change, { provider }, scenario);
      assert.deepEqual(result, { version: 1, operation: 'assistant', status: 'error', reason: 'invalid_assistant_response' });
      assertReadOnlyCall(calls, provider, change);
    }
  }
});
