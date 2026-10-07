import { fail } from './errors.mjs';

export const SNIPPET_LIMITS = Object.freeze({ count: 128, triggerCodePoints: 120, expansionBytes: 8192, totalExpansionBytes: 65536 });
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
const controls = /[\x00-\x1f\x7f-\x9f\u2028\u2029]/u;
const textControls = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/u;
const word = /[\p{L}\p{N}\p{M}_]/u;

export function sameTrigger(left, right) {
  return new RegExp(`^(?:${escape(left)})$`, 'iu').test(right);
}

export function validateSnippets(value = []) {
  if (!Array.isArray(value) || value.length > SNIPPET_LIMITS.count) fail('invalid_snippets');
  let bytes = 0;
  const result = [];
  for (const item of value) {
    if (item === null || typeof item !== 'object' || Array.isArray(item) ||
        Object.keys(item).some((key) => !['trigger', 'expansion'].includes(key))) fail('invalid_snippets');
    const { trigger, expansion } = item;
    if (typeof trigger !== 'string' || !trigger || trigger.trim() !== trigger ||
        [...trigger].length > SNIPPET_LIMITS.triggerCodePoints || controls.test(trigger) ||
        typeof expansion !== 'string' || !expansion.trim() || textControls.test(expansion) ||
        Buffer.byteLength(expansion) > SNIPPET_LIMITS.expansionBytes) fail('invalid_snippets');
    bytes += Buffer.byteLength(expansion);
    if (bytes > SNIPPET_LIMITS.totalExpansionBytes) fail('snippets_too_large');
    if (result.some((previous) => sameTrigger(previous.trigger, trigger))) fail('duplicate_snippet_trigger');
    result.push({ trigger, expansion });
  }
  return result;
}

// Match only the original input. A longer overlapping phrase wins even when it
// begins later; replacement text is literal and is never searched a second time.
export function expandSnippets(text, snippets, maxBytes = 65536) {
  const groups = new Map();
  snippets.forEach((snippet, order) => {
    const length = [...snippet.trigger].length;
    if (!groups.has(length)) groups.set(length, []);
    groups.get(length).push({ ...snippet, order });
  });
  const used = new Uint8Array(text.length), selected = [];
  for (const length of [...groups.keys()].sort((a, b) => b - a)) {
    const candidates = [];
    for (const snippet of groups.get(length)) {
      const expression = new RegExp(`(?=(${escape(snippet.trigger)}))`, 'giu');
      for (const match of text.matchAll(expression)) {
        const start = match.index, end = start + match[1].length;
        const before = start > 0 ? Array.from(text.slice(Math.max(0, start - 2), start)).at(-1) : '';
        const after = end < text.length ? String.fromCodePoint(text.codePointAt(end)) : '';
        if ((before && word.test(before)) || (after && word.test(after))) continue;
        candidates.push({ start, end, ...snippet });
      }
    }
    candidates.sort((a, b) => a.start - b.start || a.order - b.order);
    for (const candidate of candidates) {
      let overlap = false;
      for (let i = candidate.start; i < candidate.end; i++) if (used[i]) { overlap = true; break; }
      if (overlap) continue;
      used.fill(1, candidate.start, candidate.end);
      selected.push(candidate);
    }
  }
  selected.sort((a, b) => a.start - b.start);
  const parts = []; let position = 0, bytes = 0;
  for (const item of selected) {
    const before = text.slice(position, item.start);
    bytes += Buffer.byteLength(before) + Buffer.byteLength(item.expansion);
    if (bytes > maxBytes) fail('expanded_input_too_large');
    parts.push(before, item.expansion); position = item.end;
  }
  const tail = text.slice(position);
  if (bytes + Buffer.byteLength(tail) > maxBytes) fail('expanded_input_too_large');
  parts.push(tail);
  return parts.join('');
}
