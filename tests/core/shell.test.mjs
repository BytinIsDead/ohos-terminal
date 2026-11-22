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

import { Shell } from '../.build/core/shell/Shell.ts';
import { FileEntry } from '../.build/core/fs/FileEntry.ts';

class MemFs {
  constructor() {
    this.cwd = '/';
    this.nodes = new Map();
    this.nodes.set('/', { isDir: true, content: '', mode: 0o040755, mtime: 1 });
  }

  _parent(path) {
    const index = path.lastIndexOf('/');
    return index <= 0 ? '/' : path.slice(0, index);
  }

  _entry(path, node) {
    const name = path === '/' ? '/' : path.slice(path.lastIndexOf('/') + 1);
    return new FileEntry(name, path, node.isDir, false,
      node.isDir ? 0 : Buffer.byteLength(node.content, 'utf8'), node.mtime,
      node.mode, node.isDir ? 0 : 1000, node.isDir ? 0 : 1000, '', '', 'local');
  }

  stat(path) {
    const node = this.nodes.get(path);
    return node === undefined ? null : this._entry(path, node);
  }

  list(path) {
    const node = this.nodes.get(path);
    if (node === undefined || !node.isDir) {
      throw new Error('not a directory');
    }
    const prefix = path === '/' ? '/' : path + '/';
    const out = [];
    for (const [candidate, child] of this.nodes) {
      if (candidate !== path && candidate.startsWith(prefix) &&
          candidate.slice(prefix.length).indexOf('/') < 0) {
        out.push(this._entry(candidate, child));
      }
    }
    return out;
  }

  readText(path) {
    const node = this.nodes.get(path);
    if (node === undefined) {
      throw new Error('no such file');
    }
    if (node.isDir) {
      throw new Error('is a directory');
    }
    return node.content;
  }

  writeText(path, text, append) {
    const existing = this.nodes.get(path);
    if (existing !== undefined) {
      if (existing.isDir) {
        throw new Error('is a directory');
      }
      existing.content = append ? existing.content + text : text;
      return;
    }
    const parent = this.nodes.get(this._parent(path));
    if (parent === undefined || !parent.isDir) {
      throw new Error('no parent');
    }
    this.nodes.set(path, { isDir: false, content: text, mode: 0o100644, mtime: 2 });
  }

  mkdir(path) {
    const parent = this.nodes.get(this._parent(path));
    if (parent === undefined || !parent.isDir) {
      throw new Error('no parent');
    }
    if (this.nodes.has(path)) {
      throw new Error('exists');
    }
    this.nodes.set(path, { isDir: true, content: '', mode: 0o040755, mtime: 3 });
  }

  remove(path) {
    for (const candidate of [...this.nodes.keys()]) {
      if (candidate === path || candidate.startsWith(path + '/')) {
        this.nodes.delete(candidate);
      }
    }
  }

  rename(from, to) {
    for (const candidate of [...this.nodes.keys()]) {
      if (candidate === from || candidate.startsWith(from + '/')) {
        const moved = this.nodes.get(candidate);
        this.nodes.delete(candidate);
        this.nodes.set(to + candidate.slice(from.length), moved);
      }
    }
  }

  copy(from, to) {
    for (const candidate of [...this.nodes.keys()]) {
      if (candidate === from || candidate.startsWith(from + '/')) {
        this.nodes.set(to + candidate.slice(from.length), { ...this.nodes.get(candidate) });
      }
    }
  }

  readlink() {
    throw new Error('not a symlink');
  }
}

function makeShell() {
  const fs = new MemFs();
  return { fs, shell: new Shell(fs, 'tester', 'ohos') };
}

const out = result => result.lines.join('\n');

test('prompt and builtins', () => {
  const { shell } = makeShell();
  assert.equal(shell.prompt(), 'tester@ohos:~$ ');
  assert.deepEqual(shell.execute('pwd').lines, ['/']);
  assert.equal(shell.execute('whoami').lines[0], 'tester');
  assert.equal(shell.execute('hostname').lines[0], 'ohos');
  assert.equal(shell.execute('true').code, 0);
  assert.equal(shell.execute('false').code, 1);
});

test('mkdir, redirection, append and cat', () => {
  const { shell, fs } = makeShell();
  assert.equal(shell.execute('mkdir -p /docs/img').code, 0);
  assert.ok(fs.stat('/docs/img').isDir);
  assert.deepEqual(shell.execute('echo hello > /docs/a.txt').lines, []);
  assert.equal(fs.readText('/docs/a.txt'), 'hello\n');
  shell.execute('echo world >> /docs/a.txt');
  assert.equal(fs.readText('/docs/a.txt'), 'hello\nworld\n');
  assert.deepEqual(shell.execute('cat /docs/a.txt').lines, ['hello', 'world']);
  assert.deepEqual(shell.execute('cat -n /docs/a.txt').lines,
    ['     1  hello', '     2  world']);
});

test('pipes, grep, wc, head and sort', () => {
  const { shell } = makeShell();
  shell.execute('mkdir -p /docs');
  shell.execute('echo b > /docs/x.txt');
  shell.execute('echo a >> /docs/x.txt');
  assert.deepEqual(shell.execute('cat /docs/x.txt | sort').lines, ['a', 'b']);
  assert.deepEqual(shell.execute('grep -n b /docs/x.txt').lines, ['1:b']);
  assert.deepEqual(shell.execute('cat /docs/x.txt | grep -v b').lines, ['a']);
  assert.deepEqual(shell.execute('cat /docs/x.txt | wc -l').lines, ['      2']);
  assert.deepEqual(shell.execute('cat /docs/x.txt | head -n 1').lines, ['b']);
  assert.deepEqual(shell.execute('cat /docs/x.txt | tail -n 1').lines, ['a']);
});

test('ls flavours', () => {
  const { shell } = makeShell();
  shell.execute('mkdir -p /docs/img');
  shell.execute('echo hi > /docs/a.txt');
  shell.execute('echo hi > /docs/b.txt');
  const plain = out(shell.execute('ls /docs'));
  assert.equal(plain, 'img/  a.txt  b.txt');
  shell.execute('touch /docs/.hidden');
  assert.ok(out(shell.execute('ls -a /docs')).includes('.hidden'));
  assert.ok(!out(shell.execute('ls /docs')).includes('.hidden'));
  const long = out(shell.execute('ls -l /docs/a.txt'));
  assert.match(long, /^-rw-r--r--/);
  assert.match(long, /a\.txt$/);
  assert.deepEqual(shell.execute('ls /docs/*.txt').lines, ['a.txt', 'b.txt']);
});

test('cd, cd .., cd ~ and $PWD', () => {
  const { shell, fs } = makeShell();
  shell.execute('mkdir -p /work/deep');
  shell.execute('cd /work/deep');
  assert.equal(fs.cwd, '/work/deep');
  assert.equal(shell.prompt(), 'tester@ohos:/work/deep$ ');
  assert.deepEqual(shell.execute('echo $PWD').lines, ['/work/deep']);
  shell.execute('cd ..');
  assert.equal(fs.cwd, '/work');
  shell.execute('cd');
  assert.equal(fs.cwd, '/');
  assert.equal(shell.execute('cd /missing').code, 1);
});

test('cp, mv, rm and stat', () => {
  const { shell, fs } = makeShell();
  shell.execute('mkdir -p /docs');
  shell.execute('echo body > /docs/a.txt');
  assert.equal(shell.execute('cp /docs/a.txt /docs/b.txt').code, 0);
  assert.equal(fs.readText('/docs/b.txt'), 'body\n');
  assert.equal(shell.execute('mv /docs/b.txt /docs/c.txt').code, 0);
  assert.equal(fs.stat('/docs/b.txt'), null);
  assert.equal(fs.readText('/docs/c.txt'), 'body\n');
  const stat = out(shell.execute('stat /docs/c.txt'));
  assert.match(stat, /Size: 5/);
  assert.match(stat, /Mode: \(0644\) -rw-r--r--/);
  assert.match(stat, /regular file/);
  shell.execute('mkdir -p /docs/img/sub');
  assert.equal(shell.execute('rm /docs/img').code, 1);
  assert.equal(shell.execute('rm -r /docs/img').code, 0);
  assert.equal(fs.stat('/docs/img'), null);
});

test('du and df', () => {
  const { shell } = makeShell();
  shell.execute('mkdir -p /docs');
  shell.execute('echo 1234567890 > /docs/a.txt');
  const human = out(shell.execute('du -h /docs/a.txt'));
  assert.equal(human.trim(), '11 B\t/docs/a.txt');
  assert.match(out(shell.execute('df')), /Filesystem/);
});

test('quoting and variable expansion', () => {
  const { shell } = makeShell();
  assert.deepEqual(shell.execute("echo '$HOME'").lines, ['$HOME']);
  assert.deepEqual(shell.execute('echo "home is $HOME"').lines, ['home is /']);
  assert.deepEqual(shell.execute('echo $USER').lines, ['tester']);
  shell.execute('false');
  assert.deepEqual(shell.execute('echo $?').lines, ['1']);
  shell.execute('true');
  assert.deepEqual(shell.execute('echo $?').lines, ['0']);
  assert.deepEqual(shell.execute('echo a\\ b').lines, ['a b']);
});

test('exit codes propagate across a line', () => {
  const { shell } = makeShell();
  const result = shell.execute('false; echo $?');
  assert.deepEqual(result.lines, ['1']);
  assert.equal(result.code, 0);
});

test('syntax errors and unknown commands', () => {
  const { shell } = makeShell();
  assert.equal(shell.execute('echo "unterminated').code, 2);
  assert.equal(shell.execute('ls |').code, 2);
  const missing = shell.execute('frobnicate');
  assert.equal(missing.code, 127);
  assert.equal(missing.lines[0], 'ohsh: frobnicate: command not found');
  assert.deepEqual(shell.execute('pwd;').lines, ['/']);
});

test('history and clear', () => {
  const { shell } = makeShell();
  shell.execute('pwd');
  shell.execute('whoami');
  assert.equal(shell.recall(-1), 'whoami');
  assert.equal(shell.recall(-1), 'pwd');
  assert.equal(shell.recall(1), 'whoami');
  const history = out(shell.execute('history'));
  assert.match(history, /1 {2}pwd/);
  assert.match(history, /2 {2}whoami/);
  const cleared = shell.execute('clear');
  assert.equal(cleared.clear, true);
});

test('completion for commands and paths', () => {
  const { shell } = makeShell();
  const command = shell.complete('ca', 2);
  assert.equal(command.line, 'cat ');
  assert.deepEqual(command.candidates, ['cat']);
  shell.execute('mkdir -p /docs');
  const path = shell.complete('cat /do', 7);
  assert.equal(path.line, 'cat /docs/ ');
  assert.equal(path.caret, 11);
  const cd = shell.complete('ls /', 4);
  assert.ok(cd.candidates.includes('/docs/'));
});

test('exit marks the shell as finished', () => {
  const { shell } = makeShell();
  const result = shell.execute('exit');
  assert.equal(result.exit, true);
  assert.equal(shell.isExited(), true);
});
