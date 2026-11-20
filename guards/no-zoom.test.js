import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The page feels like an app, not a web page: no pinch or double-tap zoom.
// OpsScripts' standard-check holds the same rule, but it cannot run on this
// public repo's CI, so the page is checked here.
const page = readFileSync(new URL('../index.html', import.meta.url), 'utf8');

test('the viewport tag blocks zoom', () => {
  const tag = page.match(/<meta[^>]*name="viewport"[^>]*>/)?.[0] ?? '';
  assert.match(tag, /maximum-scale=1(\.0)?/);
  assert.match(tag, /user-scalable=no/);
});

test('the page sets touch-action so iOS does not zoom either', () => {
  assert.match(page, /touch-action:\s*pan-x pan-y/);
});

test('text follows the system text size on Android and iOS', () => {
  assert.match(page, /<meta[^>]*name="text-scale"[^>]*content="scale"/);
  assert.match(page, /font:\s*-apple-system-body/);
  assert.doesNotMatch(page, /font-size:\s*[\d.]+px|text-\[[\d.]+px\]/);
});

test('sizes are px-equivalent at the default text size on iOS too', () => {
  assert.match(page, /--text-px:\s*calc\(1rem \/ 16\)/);
  assert.match(page, /--text-px:\s*calc\(1rem \/ 17\)/);
});
