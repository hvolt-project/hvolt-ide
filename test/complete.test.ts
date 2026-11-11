// Tests for composer completion: command and file suggestions, and what accepting one produces.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applySuggestion, COMMANDS, suggestFor
} from '../app/src/pages/model/Complete.ts';

const FILES = ['src/main.ets', 'src/pages/Index.ets', 'README.md', 'docs/Notes.md'];

test('a slash offers commands that extend what was typed', () => {
  const found = suggestFor('/', FILES);
  assert.equal(found.kind, 'cmd');
  assert.deepEqual(found.items, COMMANDS);
});

test('a partial command narrows the list', () => {
  assert.deepEqual(suggestFor('/re', FILES).items, ['/reset']);
});

test('an exactly typed command is not offered back', () => {
  assert.deepEqual(suggestFor('/reset', FILES).items, []);
});

test('command matching is case-insensitive', () => {
  assert.deepEqual(suggestFor('/RE', FILES).items, ['/reset']);
});

test('@ with nothing after it lists files', () => {
  const found = suggestFor('look at @', FILES);
  assert.equal(found.kind, 'file');
  assert.equal(found.items.length, FILES.length);
});

test('@ narrows by substring, case-insensitively', () => {
  assert.deepEqual(suggestFor('@index', FILES).items, ['src/pages/Index.ets']);
  assert.deepEqual(suggestFor('@MD', FILES).items, ['README.md', 'docs/Notes.md']);
});

test('a space after the @ token ends completion', () => {
  const found = suggestFor('@src and more', FILES);
  assert.equal(found.kind, '');
  assert.deepEqual(found.items, []);
});

test('the last @ wins', () => {
  assert.deepEqual(suggestFor('mail me at a@b and @read', FILES).items, ['README.md']);
});

test('plain text offers nothing', () => {
  const found = suggestFor('just a question', FILES);
  assert.equal(found.kind, '');
  assert.deepEqual(found.items, []);
});

test('leading whitespace does not hide a slash', () => {
  assert.equal(suggestFor('   /he', FILES).kind, 'cmd');
});

test('the file list is capped', () => {
  const many: string[] = [];
  for (let i = 0; i < 30; i++) {
    many.push('f' + i + '.ets');
  }
  assert.equal(suggestFor('@f', many).items.length, 8);
});

test('accepting a command replaces the whole draft', () => {
  assert.equal(applySuggestion('/re', 'cmd', '/reset'), '/reset');
});

test('accepting a file replaces only the token and leaves a trailing space', () => {
  assert.equal(applySuggestion('look at @in', 'file', 'src/pages/Index.ets'),
    'look at @src/pages/Index.ets ');
});

test('accepting a file keeps text before the @', () => {
  assert.equal(applySuggestion('please read @re', 'file', 'README.md'),
    'please read @README.md ');
});

test('accepting a file with no @ appends it', () => {
  assert.equal(applySuggestion('text', 'file', 'README.md'), 'textREADME.md');
});
