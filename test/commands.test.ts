// Tests for command construction and the one hvolt.toml field the app reads.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  argvAbcRecords, argvAgcLoginCallback, argvAgcLoginUrl, argvAgcLoginWait, argvAgcWhoami, argvBuild,
  argvConnect, argvDeviceList, argvLog, argvPush, argvRun, argvSign, argvStart, argvVersion,
  parseBundle
} from '../app/src/pages/model/Commands.ts';

test('the bundle comes from hvolt.toml when declared', () => {
  const toml = '[module]\nname = "entry"\nbundle = "com.example.demo"\n';
  assert.equal(parseBundle(toml, 'fallback'), 'com.example.demo');
});

test('a file without a bundle falls back', () => {
  assert.equal(parseBundle('[module]\nname = "entry"\n', 'fallback'), 'fallback');
});

test('whitespace around the assignment is tolerated', () => {
  assert.equal(parseBundle('bundle   =   "a.b.c"', 'x'), 'a.b.c');
});

test('the fallback is used for an empty document', () => {
  assert.equal(parseBundle('', 'fallback'), 'fallback');
});

test('build and sign are bare subcommands', () => {
  assert.deepEqual(argvBuild(), ['build']);
  assert.deepEqual(argvSign(), ['sign']);
});

test('push names the device and the package, in that order', () => {
  assert.deepEqual(argvPush('127.0.0.1:8710', '/p/build/entry-signed.hap'),
    ['push', '127.0.0.1:8710', '--hap', '/p/build/entry-signed.hap']);
});

test('start appends the ability and the device flag', () => {
  assert.deepEqual(argvStart('com.example.demo', '127.0.0.1:8710'),
    ['start', 'com.example.demo/EntryAbility', '-d', '127.0.0.1:8710']);
});

test('run takes only the device', () => {
  assert.deepEqual(argvRun('dev:1'), ['run', 'dev:1']);
});

test('log passes bundle and tail as flags', () => {
  assert.deepEqual(argvLog('dev:1', 'com.a.b', 120),
    ['log', '-d', 'dev:1', '--bundle', 'com.a.b', '--tail', '120']);
});

test('the tail count is a string even when zero', () => {
  assert.deepEqual(argvLog('d', 'b', 0), ['log', '-d', 'd', '--bundle', 'b', '--tail', '0']);
});

test('device and agc subcommands keep their verbs', () => {
  assert.deepEqual(argvConnect('127.0.0.1:8710'), ['device', 'connect', '127.0.0.1:8710']);
  assert.deepEqual(argvDeviceList(), ['device', 'list']);
  assert.deepEqual(argvAgcWhoami(), ['agc', 'whoami']);
  assert.deepEqual(argvAgcLoginUrl(), ['agc', 'login', '--print-url']);
  assert.deepEqual(argvAgcLoginWait(8080), ['agc', 'login', '--wait', '8080']);
  assert.deepEqual(argvAgcLoginCallback('app://cb'), ['agc', 'login', '--callback', 'app://cb']);
});

test('abc-records takes the package path positionally', () => {
  assert.deepEqual(argvAbcRecords('/p/build/x.abc'), ['abc-records', '/p/build/x.abc']);
});

test('version is a flag, not a subcommand', () => {
  assert.deepEqual(argvVersion(), ['--version']);
});
