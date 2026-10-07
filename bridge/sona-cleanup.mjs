#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { cleanup, doctor, MAX_INPUT } from './cleanup.mjs';
import { dispatchRequest, MAX_REQUEST, requestFailure } from './operations.mjs';
import { assistantCatalog } from './assistant.mjs';

const controller = new AbortController();
process.once('SIGTERM', () => controller.abort());
process.once('SIGINT', () => controller.abort());
process.stdout.on('error', () => { controller.abort(); process.exitCode = 1; });
const diagnostic = (code) => process.stderr.write(`sona-cleanup: fallback (${code})\n`);

let options = {}, argumentError = false;
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--doctor' || arg === '--help' || arg === '--request' || arg === '--catalog') options[arg.slice(2)] = true;
  else if ((arg === '--config' || arg === '--mode') && process.argv[i + 1]) options[arg.slice(2)] = process.argv[++i];
  else argumentError = true;
}
if (options.help) {
  process.stdout.write('Usage: node sona-cleanup.mjs --config PATH [--mode prose|strict]\nRaw UTF-8 transcript on stdin. Cleaned text or exact original on stdout.\n--request accepts one versioned JSON operation and emits one JSON result.\n--doctor checks local availability without sending data.\n--catalog reads installed CLI model metadata without a generation request. Requires Node 20+.\n');
} else if (options.catalog) {
  try {
    if (argumentError || options.request || options.doctor || options.mode !== undefined) throw new Error();
    const config = options.config ? JSON.parse(await readFile(options.config, 'utf8')) : {};
    process.stdout.write(JSON.stringify(await assistantCatalog(config, { signal: controller.signal })) + '\n');
  } catch { process.stdout.write(JSON.stringify({ version: 1, operation: 'catalog', status: 'error', reason: 'catalog_unavailable' }) + '\n'); }
} else if (options.request) {
  let request, chunks = [], count = 0, oversized = false;
  try {
    for await (const chunk of process.stdin) {
      count += chunk.length;
      if (count > MAX_REQUEST) { oversized = true; chunks = []; }
      else if (!oversized) chunks.push(chunk);
    }
    if (oversized) throw Object.assign(new Error(), { reason: 'request_too_large' });
    try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); }
    catch { throw Object.assign(new Error(), { reason: 'invalid_request_json' }); }
    if (argumentError || options.doctor || options.mode !== undefined) throw Object.assign(new Error(), { reason: 'invalid_arguments' });
    let config;
    try { config = options.config ? JSON.parse(await readFile(options.config, 'utf8')) : {}; }
    catch { throw Object.assign(new Error(), { reason: 'invalid_config' }); }
    process.stdout.write(JSON.stringify(await dispatchRequest(request, config, {
      signal: controller.signal, diagnose: (code) => process.stderr.write(`sona-cleanup: operation failed (${code})\n`),
    })) + '\n');
  } catch (error) {
    process.stdout.write(JSON.stringify(requestFailure(request, error.reason ?? 'request_failed')) + '\n');
  }
} else if (options.doctor) {
  try {
    if (argumentError) throw new Error();
    const config = options.config ? JSON.parse(await readFile(options.config, 'utf8')) : {};
    process.stdout.write(JSON.stringify(await doctor(config), null, 2) + '\n');
  } catch { process.stderr.write('sona-cleanup: invalid configuration\n'); process.exitCode = 1; }
} else {
  let chunks = [], count = 0, streamingFallback = false;
  for await (const chunk of process.stdin) {
    count += chunk.length;
    if (!streamingFallback && count > MAX_INPUT) {
      streamingFallback = true; diagnostic('input_too_large');
      for (const previous of chunks) process.stdout.write(previous);
      chunks = [];
    }
    if (streamingFallback) process.stdout.write(chunk); else chunks.push(chunk);
  }
  if (!streamingFallback) {
    const raw = Buffer.concat(chunks).toString('utf8');
    try {
      if (argumentError) throw new Error();
      const config = options.config ? JSON.parse(await readFile(options.config, 'utf8')) : {};
      process.stdout.write(await cleanup(raw, config, { mode: options.mode, signal: controller.signal, diagnose: diagnostic }));
    } catch { diagnostic('invalid_config'); process.stdout.write(raw); }
  }
}
