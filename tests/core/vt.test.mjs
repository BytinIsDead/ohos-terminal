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
  VtScreen, VT_BOLD, VT_FG_DEFAULT, VT_TRUE_COLOR
} from '../.build/core/ansi/VtScreen.ts';

const enc = new TextEncoder();
const feed = (screen, text) => screen.feed(enc.encode(text));

test('plain text lands on the first line', () => {
  const screen = new VtScreen(10, 4);
  feed(screen, 'hello');
  assert.equal(screen.dumpText().split('\n')[0], 'hello');
  assert.equal(screen.cursor().col, 5);
});

test('cursor addressing and erase-to-end-of-line', () => {
  const screen = new VtScreen(10, 4);
  feed(screen, '\x1b[2;3HABC');
  const line = screen.lineAt(1, 0);
  assert.equal(line[2].ch, 'A');
  assert.equal(line[4].ch, 'C');
  feed(screen, '\x1b[2;3H\x1b[K');
  assert.ok(screen.lineAt(1, 0).every(cell => cell.ch === ' '));
});

test('SGR 16-colour and bold', () => {
  const screen = new VtScreen(10, 2);
  feed(screen, '\x1b[1;31mX');
  const cell = screen.lineAt(0, 0)[0];
  assert.equal(cell.ch, 'X');
  assert.equal(cell.fg, 1);
  assert.equal(cell.flags & VT_BOLD, VT_BOLD);
  feed(screen, '\x1b[0mY');
  assert.equal(screen.lineAt(0, 0)[1].fg, VT_FG_DEFAULT);
});

test('SGR 256-colour and 24-bit colour', () => {
  const screen = new VtScreen(10, 2);
  feed(screen, '\x1b[38;5;196mX');
  assert.equal(screen.lineAt(0, 0)[0].fg, 196);
  feed(screen, '\x1b[38;2;10;20;30mY');
  assert.equal(screen.lineAt(0, 0)[1].fg, VT_TRUE_COLOR | (10 << 16) | (20 << 8) | 30);
});

test('scrollback keeps pushed-off lines addressable', () => {
  const screen = new VtScreen(10, 3);
  feed(screen, '1\r\n2\r\n3\r\n4\r\n5');
  assert.equal(screen.maxOffset(), 2);
  assert.equal(screen.lineAt(0, 2).map(c => c.ch).join(''), '1'.padEnd(10, ' '));
  assert.equal(screen.dumpText(), '3\n4\n5\n');
  screen.scrollBy(10);
  assert.equal(screen.currentOffset(), 2);
  screen.scrollToBottom();
  assert.equal(screen.currentOffset(), 0);
});

test('deferred autowrap moves to the next line on overflow', () => {
  const screen = new VtScreen(4, 3);
  feed(screen, 'abcd');
  assert.equal(screen.cursor().row, 0);
  assert.equal(screen.cursor().col, 3);
  feed(screen, 'e');
  assert.equal(screen.cursor().row, 1);
  assert.equal(screen.dumpText().split('\n')[0], 'abcd');
  assert.equal(screen.dumpText().split('\n')[1], 'e');
});

test('OSC 0 sets the title, BEL terminates', () => {
  const screen = new VtScreen(10, 2);
  feed(screen, '\x1b]0;My Title\x07');
  assert.equal(screen.title, 'My Title');
  feed(screen, '\x1b]2;Second\x1b\\');
  assert.equal(screen.title, 'Second');
});

test('bracketed paste mode toggles', () => {
  const screen = new VtScreen(10, 2);
  feed(screen, '\x1b[?2004h');
  assert.equal(screen.bracketedPaste, true);
  feed(screen, '\x1b[?2004l');
  assert.equal(screen.bracketedPaste, false);
});

test('alternate screen preserves the main buffer', () => {
  const screen = new VtScreen(10, 3);
  feed(screen, 'MAIN');
  feed(screen, '\x1b[?1049h');
  feed(screen, 'ALT');
  assert.equal(screen.dumpText().split('\n')[0], 'ALT');
  feed(screen, '\x1b[?1049l');
  assert.equal(screen.dumpText().split('\n')[0], 'MAIN');
});

test('UTF-8 multibyte and wide characters', () => {
  const screen = new VtScreen(10, 2);
  feed(screen, 'é你');
  const line = screen.lineAt(0, 0);
  assert.equal(line[0].ch, 'é');
  assert.equal(line[1].ch, '你');
  assert.equal(line[2].ch, '', 'wide char reserves a continuation cell');
  assert.equal(screen.cursor().col, 3);
});

test('device status report writes a response string', () => {
  const screen = new VtScreen(10, 4);
  feed(screen, '\x1b[3;4H\x1b[6n');
  assert.equal(screen.takeResponses(), '\x1b[3;4R');
  feed(screen, '\x1b[c');
  assert.equal(screen.takeResponses(), '\x1b[?6c');
});

test('cursor visibility follows DECSET 25', () => {
  const screen = new VtScreen(10, 2);
  assert.equal(screen.cursor().visible, true);
  feed(screen, '\x1b[?25l');
  assert.equal(screen.cursor().visible, false);
  feed(screen, '\x1b[?25h');
  assert.equal(screen.cursor().visible, true);
});

test('resize keeps content and clamps the cursor', () => {
  const screen = new VtScreen(20, 5);
  feed(screen, 'abcdef\r\nghijkl');
  screen.resize(5, 2);
  assert.equal(screen.dumpText(), 'abcde\nghijk\n');
});
