// Deterministic check on a dictation cleanup result. Cleanup is an AI rewrite
// of the speech engine's text; in rare cases it returns a refusal, drops a
// paragraph, pastes the vocabulary list, or softens profanity. When this guard
// trips, the caller pastes the exact raw transcript and logs only the returned
// fixed reason code. It never returns or logs transcript text.
//
// Limits (2026-11-04 accuracy bench, tuned against ~1,600 saved cleanup outputs):
// trip when cleanup drops at least 4 words and more than 8% of them, more than
// 30% of its words (and more than 4) are new, a swear word is lost, the word
// edit distance exceeds 35% of the raw words (and 4), or fewer than 75% of the
// raw words remain (and at least 2 are gone). The floors keep one-word fixes in
// short dictations from tripping.

export const GUARD_REASONS = Object.freeze([
  'cleanup_guard_profanity',
  'cleanup_guard_dropped_words',
  'cleanup_guard_new_words',
  'cleanup_guard_changed_words',
  'cleanup_guard_kept_words',
]);

// Removing these is the cleanup's job, so neither side counts them.
const FILLER = new Set(['um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'ah', 'hm', 'hmm', 'mm', 'mhm']);

const ONES = 'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen'.split(' ');
const TENS = '_ _ twenty thirty forty fifty sixty seventy eighty ninety'.split(' ');
const ORDINAL = { one: 'first', two: 'second', three: 'third', five: 'fifth', eight: 'eighth', nine: 'ninth', twelve: 'twelfth' };
const SCALES = [[1e9, 'billion'], [1e6, 'million'], [1e3, 'thousand']];
const CONTRACTIONS = [['gonna', 'going to'], ['wanna', 'want to'], ['gotta', 'got to'], ['kinda', 'kind of'], ['ok', 'okay'],
  ['alright', 'all right'], ['e mail', 'email'], ['a hundred', 'one hundred'], ['a thousand', 'one thousand']];

function spell(n) {
  if (n < 20) return ONES[n];
  if (n < 100) return TENS[Math.floor(n / 10)] + (n % 10 ? ' ' + ONES[n % 10] : '');
  if (n < 1000) return ONES[Math.floor(n / 100)] + ' hundred' + (n % 100 ? ' ' + spell(n % 100) : '');
  for (const [size, name] of SCALES) {
    if (n >= size) return spell(Math.floor(n / size)) + ' ' + name + (n % size ? ' ' + spell(n % size) : '');
  }
  return String(n);
}
// Digit runs too long for exact integer arithmetic stay digits on both sides.
const spellDigits = (digits) => digits.length > 15 ? ` ${digits} ` : ` ${spell(Number(digits))} `;
function ordinal(digits) {
  if (digits.length > 15) return digits;
  const words = spell(Number(digits)).split(' '), last = words.at(-1);
  words[words.length - 1] = ORDINAL[last] ?? (last.endsWith('y') ? last.slice(0, -1) + 'ieth' : last + 'th');
  return words.join(' ');
}

// Mirrors the accuracy bench's scorer (bench/scripts/score.py normalize) so
// spoken and written forms of a number or contraction compare as equal, then
// drops filler. Letters of every script count as words.
export function guardWords(text) {
  if (typeof text !== 'string') throw new TypeError('guard input must be a string');
  let t = text.normalize('NFC').toLowerCase().replace(/[‘’]/gu, '\'').replace(/[“”]/gu, '"');
  for (const [from, to] of [['plug-in', 'plugin'], ['e-mail', 'email'], ['walk-through', 'walkthrough']]) t = t.replaceAll(from, to);
  t = t.replace(/\$(\d[\d,]*(?:\.\d+)?)(k\b)?/gu, (_, amount, k) => amount + (k ? ' thousand' : '') + ' dollars');
  t = t.replace(/(\d)%/gu, '$1 percent');
  t = t.replace(/(\d),(?=\d{3}\b)/gu, '$1');
  t = t.replace(/(\d),(?=\d{3}\b)/gu, '$1');
  t = t.replace(/\b(\d{1,2}):00\b/gu, (_, hour) => spell(Number(hour)));
  t = t.replace(/\b(\d{1,2}):(\d{2})\b/gu, (_, hour, minute) => spell(Number(hour)) + ' ' + spell(Number(minute)));
  t = t.replace(/\b(\d+)(?:st|nd|rd|th)\b/gu, (_, digits) => ordinal(digits));
  t = t.replace(/\b(\d+)\.(\d+)\b/gu, (_, whole, part) => spellDigits(whole) + ' point ' + [...part].map((c) => ONES[Number(c)]).join(' '));
  t = t.replace(/\b(\d+)k\b/gu, (_, digits) => spellDigits(digits) + ' thousand');
  t = t.replace(/\d+/gu, spellDigits);
  t = t.replace(/\b(?:[a-z]\.){2,}/gu, (initials) => initials.replaceAll('.', ''));
  t = t.replace(/[-/_]/gu, ' ').replaceAll('\'', '').replace(/[^\p{L}\p{M}\p{N} ]+/gu, ' ');
  t = ' ' + t.replace(/\s+/gu, ' ').trim() + ' ';
  for (const [from, to] of CONTRACTIONS) t = t.replaceAll(` ${from} `, ` ${to} `).replaceAll(` ${from} `, ` ${to} `);
  return t.split(' ').filter((word) => word && !FILLER.has(word));
}

// Joined, split and masked spellings of one swear share a key, so "god damn"
// and "goddamn" match while "damn" -> "darn" or "s***" does not.
const SWEAR_STEMS = [['fuck', 'fuck'], ['shit', 'shit'], ['damn', 'damn'], ['dammit', 'damn'], ['bitch', 'bitch'],
  ['bastard', 'bastard'], ['asshole', 'ass'], ['cunt', 'cunt'], ['motherf', 'fuck']];
const SWEAR_WORDS = new Map([...['ass', 'asses', 'arse', 'jackass', 'dumbass', 'badass', 'smartass', 'kickass'].map((w) => [w, 'ass']),
  ['hell', 'hell'], ['crap', 'crap'], ['crappy', 'crap'], ['dick', 'dick'], ['dicks', 'dick'], ['dickhead', 'dick'],
  ['piss', 'piss'], ['pissed', 'piss'], ['pissing', 'piss'], ['cock', 'cock'], ['prick', 'prick'], ['pricks', 'prick'],
  ['wtf', 'wtf'], ['twat', 'twat'], ['wanker', 'wanker'], ['bollocks', 'bollocks'], ['bugger', 'bugger']]);
function swearCounts(words) {
  const counts = new Map();
  for (const word of words) {
    const key = SWEAR_WORDS.get(word) ?? SWEAR_STEMS.find(([stem]) => word.includes(stem))?.[1];
    if (key) counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

// True when the word-level Levenshtein distance is above limit. Diagonal
// furthest-reach search (Landau-Vishkin): work grows with the distance found,
// not the text length squared, and it stops once the limit is passed.
function distanceExceeds(a, b, limit) {
  const n = a.length, m = b.length, target = m - n;
  if (Math.abs(target) > limit) return true;
  const ids = new Map(), id = (word) => ids.get(word) ?? ids.set(word, ids.size).get(word);
  const x = Int32Array.from(a, id), y = Int32Array.from(b, id);
  const slide = (i, k) => { while (i < n && i + k < m && x[i] === y[i + k]) i++; return i; };
  // reach[offset + k]: furthest row of a reached on diagonal k (column = row + k).
  const offset = limit + 1, none = -(n + m + 2);
  let previous = new Int32Array(2 * limit + 3).fill(none), current = new Int32Array(2 * limit + 3).fill(none);
  previous[offset] = slide(0, 0);
  if (target === 0 && previous[offset] >= n) return false;
  for (let edits = 1; edits <= limit; edits++) {
    const low = Math.max(-edits, -n), high = Math.min(edits, m);
    for (let k = low; k <= high; k++) {
      let i = Math.max(previous[offset + k] + 1, previous[offset + k - 1], previous[offset + k + 1] + 1);
      if (i < Math.max(0, -k)) { current[offset + k] = none; continue; }
      i = slide(Math.min(i, n, m - k), k);
      current[offset + k] = i;
      if (k === target && i >= n) return false;
    }
    [previous, current] = [current, previous];
  }
  return true;
}

// Returns null when the cleaned text may be pasted, otherwise one fixed reason
// code from GUARD_REASONS. Both arguments are complete texts, not fragments.
export function cleanupGuard(raw, cleaned) {
  const before = guardWords(raw), after = guardWords(cleaned);
  const rawSwears = swearCounts(before), cleanSwears = swearCounts(after);
  for (const [key, count] of rawSwears) if ((cleanSwears.get(key) ?? 0) < count) return 'cleanup_guard_profanity';
  const dropped = before.length - after.length;
  if (dropped >= 4 && dropped > 0.08 * before.length) return 'cleanup_guard_dropped_words';
  const known = new Set(before);
  const added = after.reduce((total, word) => total + (known.has(word) ? 0 : 1), 0);
  if (added > Math.max(4, 0.3 * after.length)) return 'cleanup_guard_new_words';
  if (distanceExceeds(before, after, Math.floor(Math.max(4, 0.35 * before.length)))) return 'cleanup_guard_changed_words';
  if (dropped >= 2 && after.length < 0.75 * before.length) return 'cleanup_guard_kept_words';
  return null;
}
