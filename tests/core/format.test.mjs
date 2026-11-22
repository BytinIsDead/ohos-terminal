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
  humanSize, modeString, modeOctal, naturalCompare, sortEntries,
  filterEntries, relativeAge
} from '../.build/core/fs/Format.ts';
import { FileEntry } from '../.build/core/fs/FileEntry.ts';

function entry(name, isDir, size, mtime) {
  return new FileEntry(name, `/x/${name}`, isDir, false, size, mtime,
    0o100644, 0, 0, '', '', 'local');
}

test('humanSize formats binary units', () => {
  assert.equal(humanSize(0), '0 B');
  assert.equal(humanSize(1023), '1023 B');
  assert.equal(humanSize(1024), '1 KiB');
  assert.equal(humanSize(1536), '1.5 KiB');
  assert.equal(humanSize(1024 * 1024), '1 MiB');
  assert.equal(humanSize(1536 * 1024), '1.5 MiB');
  assert.equal(humanSize(5 * 1024 * 1024 * 1024), '5 GiB');
});

test('modeString covers regular files, dirs and links', () => {
  assert.equal(modeString(0o100644), '-rw-r--r--');
  assert.equal(modeString(0o040755), 'drwxr-xr-x');
  assert.equal(modeString(0o120777), 'lrwxrwxrwx');
  assert.equal(modeString(0), '----------');
  assert.equal(modeOctal(0o100644), '0644');
  assert.equal(modeOctal(0o040755), '0755');
});

test('naturalCompare orders embedded numbers numerically', () => {
  const names = ['file10', 'file2', 'File1', 'file1b'];
  names.sort(naturalCompare);
  assert.deepEqual(names, ['File1', 'file1b', 'file2', 'file10']);
});

test('sortEntries keeps directories first and honours direction', () => {
  const list = [entry('b.txt', false, 2, 20), entry('a.txt', false, 1, 10),
    entry('dir', true, 0, 5)];
  const byName = sortEntries(list, 'name', true, true);
  assert.deepEqual(byName.map(e => e.name), ['dir', 'a.txt', 'b.txt']);
  const bySizeDesc = sortEntries(list, 'size', false, false);
  assert.deepEqual(bySizeDesc.map(e => e.name), ['b.txt', 'a.txt', 'dir']);
  const byTime = sortEntries(list, 'time', true, false);
  assert.deepEqual(byTime.map(e => e.name), ['dir', 'a.txt', 'b.txt']);
});

test('filterEntries is case-insensitive and substring based', () => {
  const list = [entry('README.md', false, 1, 1), entry('main.ts', false, 1, 1),
    entry('docs', true, 0, 1)];
  assert.deepEqual(filterEntries(list, 'MA').map(e => e.name), ['main.ts']);
  assert.deepEqual(filterEntries(list, 'MD').map(e => e.name), ['README.md']);
  assert.equal(filterEntries(list, '   ').length, 3);
  assert.equal(filterEntries(list, 'zzz').length, 0);
});

test('relativeAge reports compact buckets', () => {
  const now = Math.floor(Date.now() / 1000);
  assert.equal(relativeAge(now - 5), 'now');
  assert.equal(relativeAge(now - 120), '2m');
  assert.equal(relativeAge(now - 7200), '2h');
  assert.equal(relativeAge(now - 86400 * 3), '3d');
  assert.equal(relativeAge(0), '');
});
