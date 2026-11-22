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
  normalizePath, resolvePath, joinPath, parentPath, baseName, pathSegments
} from '../.build/core/fs/PathUtil.ts';

test('normalizePath collapses dots and repeated slashes', () => {
  assert.equal(normalizePath('/a//b/./c/../d/'), '/a/b/d');
  assert.equal(normalizePath('/..'), '/');
  assert.equal(normalizePath('/../../x'), '/x');
  assert.equal(normalizePath(''), '/');
  assert.equal(normalizePath('/'), '/');
});

test('resolvePath treats input as relative to cwd', () => {
  assert.equal(resolvePath('/home/app', 'docs'), '/home/app/docs');
  assert.equal(resolvePath('/home/app', '../..'), '/');
  assert.equal(resolvePath('/home/app', '/etc'), '/etc');
  assert.equal(resolvePath('/home/app', ''), '/home/app');
  assert.equal(resolvePath('/home/app', '~'), '/');
  assert.equal(resolvePath('/home/app', '~/docs/./x'), '/docs/x');
});

test('joinPath, parentPath, baseName and segments', () => {
  assert.equal(joinPath('/a/b', 'c'), '/a/b/c');
  assert.equal(joinPath('/', 'c'), '/c');
  assert.equal(joinPath('/a', '/x/../y'), '/y');
  assert.equal(parentPath('/a/b/c'), '/a/b');
  assert.equal(parentPath('/a'), '/');
  assert.equal(parentPath('/'), '/');
  assert.equal(baseName('/a/b/c.txt'), 'c.txt');
  assert.equal(baseName('/'), '/');
  assert.deepEqual(pathSegments('/a/b/c'), ['a', 'b', 'c']);
  assert.deepEqual(pathSegments('/'), []);
});
