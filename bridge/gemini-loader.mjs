import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Published @google/gemini-cli 0.58.0 uses bundled chunks, not the source tree's
// importable core package. Load hooks preserve original URLs and resources.
// Exact hashes prevent a linked/mixed/changed Config from bypassing the guard.
const HASHES = Object.freeze({
  'chunk-FQCNOBUR.js': 'd3895c01c9077e0163454a3cec91988d4fec453f6a4b78ccc32c31b30f1c7bac',
  'chunk-MFLFXOVQ.js': '5934d3b3bd7fc8ea0c853b9a79e3832b51dda7c2522929d1cc3c03239dea2fde',
  'chunk-RTL6OG34.js': 'f231a4cd6cb281cb306202339f74dbb4d86068dfeb6c1e3601318f0668c899cc',
});
let bundleRoot;
export function initialize(data) { bundleRoot = data.bundleRoot; }
export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (!url.startsWith('file:') || path.dirname(fileURLToPath(url)) !== bundleRoot || result.format !== 'module') return result;
  const source = Buffer.isBuffer(result.source) ? result.source.toString('utf8') : String(result.source);
  const name = path.basename(fileURLToPath(url));
  if (HASHES[name]) {
    if (createHash('sha256').update(source).digest('hex') !== HASHES[name]) throw new Error('gemini_bundle_changed');
    return { ...result, source: source + '\nglobalThis[Symbol.for("sona.gemini.installGuard")](Config);\n' };
  }
  if (source.includes('async createToolRegistry(')) throw new Error('gemini_bundle_unverified');
  return result;
}
