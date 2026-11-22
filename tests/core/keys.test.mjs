/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  KeyEncoder, Utf8Decoder, utf8Encode, asciiBytes
} from '../.build/core/ansi/Keys.ts';

const str = bytes => Buffer.from(bytes).toString('latin1');

test('cursor keys switch between CSI and SS3 modes', () => {
  const keys = new KeyEncoder();
  assert.equal(str(keys.named('up')), '\x1b[A');
  keys.applicationCursorKeys = true;
  assert.equal(str(keys.named('up')), '\x1bOA');
  assert.equal(str(keys.named('left')), '\x1bOD');
  assert.equal(str(keys.named('home')), '\x1bOH');
});

test('editing keys use the expected sequences', () => {
  const keys = new KeyEncoder();
  assert.equal(str(keys.named('delete')), '\x1b[3~');
  assert.equal(str(keys.named('pageup')), '\x1b[5~');
  assert.equal(str(keys.named('backspace')), '\x7f');
  assert.equal(str(keys.named('enter')), '\r');
  assert.equal(str(keys.named('tab')), '\t');
  assert.equal(keys.named('nonsense').length, 0);
});

test('function keys', () => {
  const keys = new KeyEncoder();
  assert.equal(str(keys.functionKey(1)), '\x1bOP');
  assert.equal(str(keys.functionKey(5)), '\x1b[15~');
  assert.equal(str(keys.functionKey(12)), '\x1b[24~');
});

test('control codes', () => {
  const keys = new KeyEncoder();
  assert.equal(keys.controlCode('a'), 1);
  assert.equal(keys.controlCode('Z'), 26);
  assert.equal(keys.controlCode('@'), 0);
  assert.equal(keys.controlCode('['), 0x1b);
  assert.equal(keys.controlCode('?'), 0x7f);
  assert.equal(keys.controlCode('ab'), -1);
  assert.equal(keys.controlCode('1'), -1);
});

test('paste uses CR line endings and optional brackets', () => {
  const keys = new KeyEncoder();
  assert.equal(str(keys.paste('a\nb\r\nc', false)), 'a\rb\rc');
  assert.equal(str(keys.paste('x', true)), '\x1b[200~x\x1b[201~');
});

test('UTF-8 encoding round-trips through the streaming decoder', () => {
  const decoder = new Utf8Decoder();
  const bytes = utf8Encode('héllo €𝄞');
  let out = '';
  for (const byte of bytes) {
    out += decoder.push(byte);
  }
  assert.equal(out, 'héllo €𝄞');
});

test('decoder splits multibyte sequences across pushes', () => {
  const decoder = new Utf8Decoder();
  const bytes = utf8Encode('€');
  assert.equal(decoder.push(bytes[0]), '');
  assert.equal(decoder.push(bytes[1]), '');
  assert.equal(decoder.push(bytes[2]), '€');
});

test('asciiBytes leaves each UTF-16 unit in 0..255', () => {
  assert.equal(str(asciiBytes('ok')), 'ok');
  assert.equal(asciiBytes('é')[0], 0xe9);
});
