#!/usr/bin/env node
// Explicit opt-in only. Uses an existing CLI account and its normal usage quota.
// Never run by npm test. No direct API calls or credential inspection.
import { cleanup, PROVIDERS } from '../cleanup.mjs';
const provider = process.argv[2];
if (!['claude', 'codex'].includes(provider)) throw new Error('Choose claude or codex explicitly');
const input = 'um here is the plan lets make it happen';
const diagnostics = [], start = performance.now();
const output = await cleanup(input, { ai: { provider, model: 'economy', timeoutMs: 15000 } }, { diagnose: (code) => diagnostics.push(code) });
const result = { provider, model: PROVIDERS[provider].model, durationMs: Math.round(performance.now() - start),
  passed: !diagnostics.length && output !== input && /plan/iu.test(output) && /happen/iu.test(output),
  output, diagnostics, scope: 'Synthetic text only; existing CLI account; no direct API calls.' };
console.log(JSON.stringify(result, null, 2));
if (!result.passed) process.exitCode = 1;
