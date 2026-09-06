import { readFile } from 'node:fs/promises';
const configPath = process.argv[process.argv.indexOf('--config') + 1];
const scenario = (JSON.parse(await readFile(configPath, 'utf8'))).scenario;
if (scenario === 'early-close') process.exit(0);
if (scenario === 'never-read') { setInterval(() => {}, 1000); await new Promise(() => {}); }
let raw = ''; for await (const chunk of process.stdin) raw += chunk;
if (process.argv.some((arg) => arg.includes(raw))) process.exit(2);
if (scenario === 'empty') process.exit(0);
if (scenario === 'nonzero') { process.stdout.write('Do not paste this error'); process.exit(1); }
if (scenario === 'overflow') { process.stdout.write('x'.repeat(256 * 1024 + 1)); process.exit(0); }
if (scenario === 'hang') { setInterval(() => {}, 1000); await new Promise(() => {}); }
process.stdout.write('Hello, world.');
if (scenario === 'result-then-hang') { setInterval(() => {}, 1000); await new Promise(() => {}); }
