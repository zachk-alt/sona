import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const provider = process.env.SONA_TEST_PROVIDER ?? 'claude';
const scenario = process.env.SONA_TEST_CASE ?? 'success';
const args = process.argv.slice(2);
const has = (...values) => args.some((value, index) => values.every((part, offset) => args[index + offset] === part));
if (provider === 'claude') {
  assert(has('--tools', ''));
  for (const flag of ['--no-session-persistence', '--safe-mode', '--strict-mcp-config']) assert(args.includes(flag));
  assert(has('--disallowedTools', 'mcp__*'));
} else {
  for (const flag of ['--ephemeral', '--ignore-user-config', '--ignore-rules']) assert(args.includes(flag));
  assert(has('--sandbox', 'read-only'));
  for (const config of ['features.shell_tool=false', 'features.unified_exec=false', 'features.hooks=false', 'features.apps=false', 'features.multi_agent=false', 'features.plugins=false']) assert(args.includes(config));
}
if (scenario === 'early-exit') process.exit(1);
if (scenario === 'never-read') { setInterval(() => {}, 1000); await new Promise(() => {}); }
let input = '';
for await (const chunk of process.stdin) input += chunk.toString();
const payload = JSON.parse(input);
assert.equal(typeof payload.transcript, 'string');
assert(!args.some((arg) => arg.includes(payload.transcript)), 'Transcript leaked into argv');
if (scenario === 'tree') {
  const child = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { stdio: 'ignore' });
  writeFileSync(process.env.SONA_TEST_PID_FILE, String(child.pid));
  setInterval(() => {}, 1000); await new Promise(() => {});
}
if (scenario === 'silent') { setInterval(() => {}, 1000); await new Promise(() => {}); }
if (scenario === 'overflow') { process.stdout.write('x'.repeat(1024 * 1024 + 1)); process.exit(0); }
if (scenario === 'malformed') { process.stdout.write('this is not json'); process.exit(0); }
if (scenario === 'nonzero') { process.stdout.write('authentication failed'); process.exit(1); }
let result = scenario === 'echo' ? payload.transcript : 'Hello, world.';
if (scenario === 'empty') result = '';
if (scenario === 'expanded') result = 'x'.repeat(1000);
if (scenario === 'fence') result = '```Hello, world.```';
if (provider === 'claude') {
  const frame = { type: 'result', subtype: 'success', is_error: false, result };
  if (scenario === 'error-envelope') { frame.is_error = true; frame.result = 'API Error: missing authorization'; }
  if (scenario === 'subtype-error') frame.subtype = 'error_during_execution';
  if (scenario === 'errors') frame.errors = ['sensitive provider diagnostic'];
  process.stdout.write(JSON.stringify(frame));
} else {
  const frames = [{ type: 'thread.started', thread_id: 'fixture' }, { type: 'turn.started' },
    { type: 'item.completed', item: { type: 'agent_message', text: result } }, { type: 'turn.completed', usage: {} }];
  if (scenario === 'error-envelope') frames.push({ type: 'turn.failed', error: { message: 'sensitive provider diagnostic' } });
  if (scenario === 'tool') frames.unshift({ type: 'item.started', item: { type: 'command_execution', command: 'forbidden' } });
  if (scenario === 'incomplete') frames.pop();
  if (scenario === 'multiple') frames.splice(2, 0, { type: 'item.completed', item: { type: 'agent_message', text: 'extra' } });
  process.stdout.write(frames.map((frame) => JSON.stringify(frame)).join('\n'));
}
if (scenario === 'result-then-fail') process.exitCode = 1;
if (scenario === 'result-then-hang') { setInterval(() => {}, 1000); await new Promise(() => {}); }
