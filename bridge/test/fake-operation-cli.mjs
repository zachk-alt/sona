import assert from 'node:assert/strict';
import { appendFileSync, readFileSync } from 'node:fs';

// Only a count is recorded. Synthetic payloads are kept in memory, just as in
// the real bridge. This fixture never uses an account or external service.
if (process.env.SONA_TEST_COUNT_FILE) appendFileSync(process.env.SONA_TEST_COUNT_FILE, 'call\n');
const args = process.argv.slice(2), provider = process.env.SONA_TEST_PROVIDER ?? 'claude';
const value = (flag) => args[args.indexOf(flag) + 1];
assert.equal(value('--model'), provider === 'claude' ? 'claude-haiku-4-5-20251001' : 'gpt-5.6-luna');
if (provider === 'claude') {
  assert.equal(value('--tools'), '');
  for (const flag of ['--safe-mode', '--strict-mcp-config', '--no-session-persistence']) assert(args.includes(flag));
} else {
  for (const flag of ['--ephemeral', '--ignore-user-config', '--ignore-rules']) assert(args.includes(flag));
  for (const setting of ['features.shell_tool=false', 'features.multi_agent=false', 'history.persistence="none"', 'project_doc_max_bytes=0']) assert(args.includes(setting));
}
let source = '';
for await (const chunk of process.stdin) source += chunk.toString('utf8');
const payload = JSON.parse(source);
for (const field of ['transcript', 'selection', 'instruction', 'context']) {
  if (payload[field]) assert(!args.some((arg) => arg.includes(payload[field])), `${field} leaked into argv`);
}
const mode = process.env.SONA_TEST_OPERATION;
if (mode) {
  const system = provider === 'claude' ? value('--system-prompt') : readFileSync(JSON.parse(args.find((arg) => arg.startsWith('model_instructions_file=')).split('=').slice(1).join('=')), 'utf8');
  assert(system.includes(mode === 'snippet_assist' ? 'snippet proposal' : mode === 'rewrite' ? 'text-rewrite' : 'transcript'));
}
if (process.env.SONA_TEST_EXPECT_PAYLOAD) assert.deepEqual(payload, JSON.parse(process.env.SONA_TEST_EXPECT_PAYLOAD));
const scenario = process.env.SONA_TEST_CASE;
if (scenario === 'timeout') { setInterval(() => {}, 1000); await new Promise(() => {}); }
if (scenario === 'missing-login') process.exit(1);
if (scenario === 'malformed') { process.stdout.write('not JSON'); process.exit(0); }
let result = process.env.SONA_TEST_OUTPUT_JSON ? JSON.parse(process.env.SONA_TEST_OUTPUT_JSON) : process.env.SONA_TEST_OUTPUT ?? payload.transcript;
if (provider === 'claude') process.stdout.write(JSON.stringify({ type: 'result', subtype: 'success', is_error: scenario === 'error', result }));
else process.stdout.write([
  { type: 'item.completed', item: { type: scenario === 'tool' ? 'command_execution' : 'agent_message', text: result } },
  { type: 'turn.completed' },
].map((frame) => JSON.stringify(frame)).join('\n'));
if (scenario === 'result-then-fail') process.exitCode = 1;
