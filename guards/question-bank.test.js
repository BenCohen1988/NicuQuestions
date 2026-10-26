// The question bank in index.html: every entry has the shape the page reads,
// so a bad paste fails here instead of breaking the live site.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// --- Constants ---

const PAGE = new URL('../index.html', import.meta.url);
const BANK_START = 'const rawQuestions = [';
const BANK_END = '\n            ];';
const TOPICS = [1, 2, 3, 4, 5];
const DIFFICULTIES = [1, 2, 3];
// topic, difficulty, question, correct, three wrong, explanation
const FIELDS = 8;
// 1 = written by Claude, 2 = recalled from a past exam
const FLAGS = [1, 2];

// --- Helpers ---

function loadBank() {
  const html = readFileSync(PAGE, 'utf8');
  const start = html.indexOf(BANK_START);
  assert.notEqual(start, -1, 'rawQuestions not found in index.html');
  const end = html.indexOf(BANK_END, start);
  const body = html.slice(start + BANK_START.length - 1, end + BANK_END.length);
  return new Function(`return ${body}`)();
}

// --- Tests ---

test('the bank is not empty', () => {
  assert.ok(loadBank().length > 0);
});

test('every question has the fields the page reads', () => {
  for (const q of loadBank()) {
    const label = String(q[2]).slice(0, 40);
    assert.ok(q.length === FIELDS || q.length === FIELDS + 1, `wrong length: ${label}`);
    assert.ok(TOPICS.includes(q[0]), `bad topic: ${label}`);
    assert.ok(DIFFICULTIES.includes(q[1]), `bad difficulty: ${label}`);
    for (let i = 2; i < FIELDS; i++) {
      assert.equal(typeof q[i], 'string', `field ${i} is not text: ${label}`);
      assert.ok(q[i].trim(), `field ${i} is empty: ${label}`);
    }
    if (q.length > FIELDS) assert.ok(FLAGS.includes(q[FIELDS]), `bad flag: ${label}`);
  }
});

test('the correct answer is not also among the wrong ones', () => {
  for (const q of loadBank()) {
    assert.ok(![q[4], q[5], q[6]].includes(q[3]), `answer repeated: ${String(q[2]).slice(0, 40)}`);
  }
});
