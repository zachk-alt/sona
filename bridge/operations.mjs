import { MAX_INPUT, oneRequest, parseConfig, validateText } from './cleanup.mjs';
import { fail, reasonFor } from './errors.mjs';
import { expandSnippets, sameTrigger, validateSnippets } from './snippets.mjs';
import { assistantRequest, assistantSettings, validateAssistantInput } from './assistant.mjs';

export const MAX_REQUEST = 6 * 1024 * 1024;
const operations = ['dictate', 'rewrite', 'snippet_assist', 'assistant'];
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const fields = {
  dictate: ['version', 'operation', 'transcript', 'mode', 'cleanupEnabled'],
  rewrite: ['version', 'operation', 'selection', 'instruction', 'profile', 'options'],
  snippet_assist: ['version', 'operation', 'context'],
  assistant: ['version', 'operation', 'intent', 'instruction', 'images', 'context', 'options', 'messages'],
};
const textControls = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/u;
const stringInput = (value) => {
  if (typeof value !== 'string') fail('invalid_request');
  if (Buffer.byteLength(value) > MAX_INPUT) fail('input_too_large');
  if (textControls.test(value)) fail('invalid_input');
};

export function requestFailure(request, reason) {
  const operation = object(request) && operations.includes(request.operation) ? request.operation : 'unknown';
  return operation === 'dictate' && typeof request.transcript === 'string'
    ? { version: 1, operation, status: 'fallback', text: request.transcript, reason }
    : { version: 1, operation, status: 'error', reason };
}

function validateRequest(request) {
  if (!object(request) || request.version !== 1 || !operations.includes(request.operation) ||
      Object.keys(request).some((key) => !fields[request.operation].includes(key))) fail('invalid_request');
  if (request.operation === 'dictate') {
    stringInput(request.transcript);
    if (!['prose', 'strict'].includes(request.mode) || typeof request.cleanupEnabled !== 'boolean') fail('invalid_request');
  } else if (request.operation === 'rewrite') {
    stringInput(request.selection); stringInput(request.instruction);
    if (!request.selection.trim()) fail('empty_selection');
    if (!request.instruction.trim()) fail('empty_instruction');
    if (request.profile !== undefined && request.profile !== 'assistant') fail('invalid_request');
    if (request.options !== undefined && request.profile !== 'assistant') fail('invalid_request');
    if (request.options !== undefined) assistantSettings({}, request.options);
  } else if (request.operation === 'assistant') validateAssistantInput(request);
  else stringInput(request.context);
}

function rewriteText(result, selection) {
  if (typeof result !== 'string' || !result.trim() || Buffer.byteLength(result) > MAX_INPUT || textControls.test(result) ||
      (result.trim().startsWith('```') && !selection.trim().startsWith('```'))) fail('invalid_rewrite_text');
  const leading = selection.match(/^\s*/u)[0], trailing = selection.match(/\s*$/u)[0];
  const text = leading + result.trim() + trailing;
  if (Buffer.byteLength(text) > MAX_INPUT) fail('invalid_rewrite_text');
  return text;
}

function proposals(result, context, existing) {
  let response;
  try { response = JSON.parse(result); } catch { fail('invalid_snippet_proposals'); }
  if (!object(response)) fail('invalid_snippet_proposals');
  if (Object.keys(response).length === 1 && response.needs_input === true) return null;
  if (Object.keys(response).length !== 1 || !Array.isArray(response.snippets)) fail('invalid_snippet_proposals');
  const snippets = validateSnippets(response.snippets);
  if (!snippets.length) return null;
  for (const snippet of snippets) {
    // No account memory or invented values: every fixed expansion must be
    // present verbatim in the context the user explicitly supplied this time.
    if (!context.includes(snippet.expansion)) fail('snippet_expansion_not_in_context');
    if (existing.some((item) => sameTrigger(item.trigger, snippet.trigger))) fail('snippet_trigger_exists');
  }
  validateSnippets([...existing, ...snippets]);
  return snippets;
}

export async function dispatchRequest(request, rawConfig = {}, { env = process.env, signal, diagnose = () => {} } = {}) {
  try {
    validateRequest(request);
    const base = { version: 1, operation: request.operation };
    if (request.operation === 'snippet_assist' && !request.context.trim())
      return { ...base, status: 'needs_input', reason: 'context_required' };
    const config = parseConfig(rawConfig);
    if (signal?.aborted) fail('cancelled');
    if (request.operation === 'assistant') return { ...base, status: 'ok', ...await assistantRequest(request, rawConfig, { env, signal }) };
    const invoke = (payload, prompt) => oneRequest(payload, config, { prompt, env, signal, strictPolicy: true });
    if (request.operation === 'dictate') {
      const expanded = expandSnippets(request.transcript, config.snippets, MAX_INPUT);
      if (!request.cleanupEnabled || config.provider === 'none' || !expanded.trim())
        return { ...base, status: 'ok', text: expanded };
      const result = await invoke({ transcript: expanded, vocabulary: config.vocabulary }, request.mode);
      const text = validateText(result, expanded);
      if (Buffer.byteLength(text) > MAX_INPUT) fail('invalid_cleaned_text');
      return { ...base, status: 'ok', text };
    }
    if (request.operation === 'rewrite') {
      const result = request.profile === 'assistant' ? await assistantRequest(request, rawConfig, { env, signal })
        : await invoke({ selection: request.selection.trim(), instruction: request.instruction,
          vocabulary: config.vocabulary }, 'rewrite');
      return { ...base, status: 'ok', text: rewriteText(result, request.selection) };
    }
    const result = await invoke({ context: request.context }, 'snippet-assist');
    const snippets = proposals(result, request.context, config.snippets);
    return snippets ? { ...base, status: 'ok', snippets }
      : { ...base, status: 'needs_input', reason: 'context_required' };
  } catch (error) {
    const reason = reasonFor(error);
    try { diagnose(reason); } catch { /* Diagnostics cannot replace a result. */ }
    return requestFailure(request, reason);
  }
}
