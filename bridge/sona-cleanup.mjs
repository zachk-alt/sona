#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { cleanup, doctor, MAX_INPUT } from './cleanup.mjs';

const controller = new AbortController();
process.once('SIGTERM', () => controller.abort());
process.once('SIGINT', () => controller.abort());
process.stdout.on('error', () => { controller.abort(); process.exitCode = 1; });
const diagnostic = (code) => process.stderr.write(`sona-cleanup: fallback (${code})\n`);

let options = {}, argumentError = false;
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--doctor' || arg === '--help') options[arg.slice(2)] = true;
  else if ((arg === '--config' || arg === '--mode') && process.argv[i + 1]) options[arg.slice(2)] = process.argv[++i];
  else argumentError = true;
}
if (options.help) {
  process.stdout.write('Usage: node sona-cleanup.mjs --config PATH [--mode prose|strict]\nRaw UTF-8 transcript on stdin. Cleaned text or exact original on stdout.\n--doctor checks local availability without sending data. Requires Node 20+.\n');
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
