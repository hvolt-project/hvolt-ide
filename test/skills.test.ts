// Tests for the skill catalog. Run with: node --test test/
//
// The catalog is one message that gets replaced, never appended. That is the property worth
// pinning: a session that learns ten skills must not carry ten catalogs, and the empty case must
// remove the message rather than leave an empty shell behind.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  catalogFingerprint, catalogText, isCatalog, parseFrontmatter, parseSkill
} from '../app/src/pages/harness/loop/Skills.ts';

test('frontmatter is split from the body', () => {
  const parsed = parseFrontmatter('---\nname: a\ndescription: b\n---\nthe body\n');
  assert.equal(parsed.meta.get('name'), 'a');
  assert.equal(parsed.meta.get('description'), 'b');
  assert.equal(parsed.body.trim(), 'the body');
});

test('a file without frontmatter keeps its whole text', () => {
  const parsed = parseFrontmatter('# Heading\nbody\n');
  assert.equal(parsed.meta.size, 0);
  assert.ok(parsed.body.includes('# Heading'));
});

test('a skill takes its name from the directory when the header omits it', () => {
  const entry = parseSkill('arkts', '---\ndescription: d\n---\nbody');
  assert.equal(entry.name, 'arkts');
  assert.equal(entry.description, 'd');
});

test('a skill without a description falls back to its first line', () => {
  const entry = parseSkill('plain', 'This is what it does\nmore');
  assert.equal(entry.description, 'This is what it does');
});

test('the catalog lists names, sources and descriptions', () => {
  const text = catalogText([
    { name: 'b-skill', description: 'second', source: 'workspace' },
    { name: 'a-skill', description: 'first', source: 'builtin' }
  ]);
  assert.ok(text.includes('<available_skills>'));
  assert.ok(text.includes('- `a-skill`: first'), 'builtin carries no tag');
  assert.ok(text.includes('- `b-skill` [workspace]: second'));
  // Sorted, so the message is stable regardless of directory read order.
  assert.ok(text.indexOf('a-skill') < text.indexOf('b-skill'));
});

test('an empty catalog is empty text, so the message can be removed', () => {
  assert.equal(catalogText([]), '');
});

test('the fingerprint changes only when the content does', () => {
  const one = [{ name: 'a', description: 'x', source: 'builtin' }];
  const same = [{ name: 'a', description: 'x', source: 'builtin' }];
  const changed = [{ name: 'a', description: 'y', source: 'builtin' }];
  const added = [
    { name: 'a', description: 'x', source: 'builtin' },
    { name: 'b', description: 'z', source: 'workspace' }
  ];
  assert.equal(catalogFingerprint(one), catalogFingerprint(same));
  assert.notEqual(catalogFingerprint(one), catalogFingerprint(changed));
  assert.notEqual(catalogFingerprint(one), catalogFingerprint(added));
});

test('the fingerprint ignores order', () => {
  const a = { name: 'a', description: 'x', source: 'builtin' };
  const b = { name: 'b', description: 'y', source: 'builtin' };
  assert.equal(catalogFingerprint([a, b]), catalogFingerprint([b, a]));
});

test('a catalog message is recognisable', () => {
  assert.equal(isCatalog(catalogText([{ name: 'a', description: 'x', source: 'builtin' }])), true);
  assert.equal(isCatalog('hello'), false);
});
