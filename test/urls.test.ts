// Tests for endpoint interpretation: the two routes derived from a stored base, and the provider
// label shown under the project name.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  chatUrl, modelsUrl, normalizeBase, providerOf
} from '../app/src/pages/harness/loop/Urls.ts';

test('a plain base is left alone', () => {
  assert.equal(normalizeBase('https://api.deepseek.com/v1'), 'https://api.deepseek.com/v1');
});

test('a pasted chat URL is reduced to its base', () => {
  assert.equal(normalizeBase('https://api.deepseek.com/v1/chat/completions'),
    'https://api.deepseek.com/v1');
});

test('trailing slashes are removed', () => {
  assert.equal(normalizeBase('https://api.deepseek.com/v1///'), 'https://api.deepseek.com/v1');
});

test('surrounding whitespace is ignored', () => {
  assert.equal(normalizeBase('  https://host/v1  '), 'https://host/v1');
});

test('an empty base stays empty', () => {
  assert.equal(normalizeBase('   '), '');
});

test('the chat route is the base plus one suffix, never two', () => {
  assert.equal(chatUrl('https://api.deepseek.com/v1'), 'https://api.deepseek.com/v1/chat/completions');
  assert.equal(chatUrl('https://api.deepseek.com/v1/chat/completions'),
    'https://api.deepseek.com/v1/chat/completions');
});

test('the models route is derived from the same base', () => {
  assert.equal(modelsUrl('https://api.deepseek.com/v1/'), 'https://api.deepseek.com/v1/models');
});

test('providerOf drops the scheme, path and api prefix', () => {
  assert.equal(providerOf('https://api.deepseek.com/v1'), 'deepseek.com');
});

test('providerOf keeps a host without the api prefix', () => {
  assert.equal(providerOf('http://localhost:11434/v1'), 'localhost:11434');
});

test('providerOf returns empty for an unset endpoint', () => {
  assert.equal(providerOf(''), '');
  assert.equal(providerOf('   '), '');
});

test('providerOf keeps a subdomain it did not add', () => {
  assert.equal(providerOf('https://foo.api.example.com/v1'), 'foo.api.example.com');
});
