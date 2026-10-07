import { oneRequest, parseConfig, validateText } from '../cleanup.mjs';
import { reasonFor } from '../errors.mjs';

// Tests only. No CLI entry point exposes this policy bypass. It retains coverage
// of dormant provider adapters without making them available to Sona operations.
export async function adapterCleanup(original, rawConfig, { mode = 'prose', env = process.env, signal, diagnose = () => {} } = {}) {
  try {
    const config = parseConfig(rawConfig);
    const result = await oneRequest({ transcript: original, vocabulary: config.vocabulary }, config,
      { prompt: mode, env, signal, strictPolicy: false });
    return validateText(result, original);
  } catch (error) { diagnose(reasonFor(error)); return original; }
}
