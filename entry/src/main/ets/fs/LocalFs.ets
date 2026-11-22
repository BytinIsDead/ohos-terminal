/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Local filesystem adapter: maps the virtual root '/' onto the application
 * sandbox directory. Normalising every path before mapping keeps the shell and
 * file browser confined to the sandbox.
 */

import fs from '@ohos.file.fs';
import { FileEntry } from '../core/fs/FileEntry';
import { ShellFs } from '../core/shell/Shell';
import { normalizePath } from '../core/fs/PathUtil';

export class LocalFs implements ShellFs {
  cwd: string = '/';
  private baseDir: string;

  constructor(baseDir: string) {
    this.baseDir = baseDir.endsWith('/')
      ? baseDir.substring(0, baseDir.length - 1) : baseDir;
  }

  root(): string {
    return this.baseDir;
  }

  /** Virtual path -> sandbox path. */
  real(path: string): string {
    const normalized: string = normalizePath(path);
    return normalized === '/' ? this.baseDir : this.baseDir + normalized;
  }

  private entry(path: string, stat: fs.Stat, isDir: boolean,
                isLink: boolean): FileEntry {
    const name: string = normalizePath(path) === '/'
      ? '/' : normalizePath(path).substring(normalizePath(path).lastIndexOf('/') + 1);
    const kind: number = isDir ? 0o040000 : 0o100000;
    const perms: number = (stat.mode & 0o777) !== 0
      ? (stat.mode & 0o777) : (isDir ? 0o755 : 0o644);
    return new FileEntry(name, normalizePath(path), isDir, isLink,
      isDir ? 0 : stat.size, stat.mtime,
      (isLink ? 0o120000 : kind) | perms, stat.uid, stat.gid, '', '', 'local');
  }

  private lstat(realPath: string): fs.Stat {
    return fs.lstatSync(realPath);
  }

  stat(path: string): FileEntry | null {
    const realPath: string = this.real(path);
    try {
      const stat: fs.Stat = this.lstat(realPath);
      let isLink: boolean = false;
      try {
        isLink = stat.isSymbolicLink();
      } catch (e) {
        isLink = false;
      }
      let isDir: boolean = stat.isDirectory();
      if (isLink) {
        try {
          isDir = fs.statSync(realPath).isDirectory();
        } catch (e) {
          isDir = false;
        }
      }
      return this.entry(path, stat, isDir, isLink);
    } catch (e) {
      return null;
    }
  }

  exists(path: string): boolean {
    return this.stat(path) !== null;
  }

  list(path: string): Array<FileEntry> {
    const realPath: string = this.real(path);
    const names: Array<string> = fs.listFileSync(realPath);
    const out: Array<FileEntry> = [];
    const base: string = normalizePath(path);
    for (let i = 0; i < names.length; i++) {
      const childPath: string = base === '/' ? `/${names[i]}` : `${base}/${names[i]}`;
      const entry: FileEntry | null = this.stat(childPath);
      if (entry !== null) {
        out.push(entry);
      }
    }
    return out;
  }

  readText(path: string): string {
    return fs.readTextSync(this.real(path));
  }

  writeText(path: string, text: string, append: boolean): void {
    let mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE;
    mode = append ? (mode | fs.OpenMode.APPEND) : (mode | fs.OpenMode.TRUNC);
    const file: fs.File = fs.openSync(this.real(path), mode);
    try {
      if (text.length > 0) {
        fs.writeSync(file.fd, text);
      }
    } finally {
      fs.closeSync(file);
    }
  }

  mkdir(path: string): void {
    fs.mkdirSync(this.real(path));
  }

  remove(path: string, dir: boolean): void {
    const realPath: string = this.real(path);
    if (dir) {
      fs.rmdirSync(realPath);
    } else {
      fs.unlinkSync(realPath);
    }
  }

  rename(from: string, to: string): void {
    fs.renameSync(this.real(from), this.real(to));
  }

  copy(from: string, to: string): void {
    const src: string = this.real(from);
    const dst: string = this.real(to);
    const stat: fs.Stat = this.lstat(src);
    if (!stat.isDirectory()) {
      fs.copyFileSync(src, dst);
      return;
    }
    try {
      fs.statSync(dst);
    } catch (e) {
      fs.mkdirSync(dst);
    }
    const names: Array<string> = fs.listFileSync(src);
    for (let i = 0; i < names.length; i++) {
      const childFrom: string = from === '/' ? `/${names[i]}` : `${from}/${names[i]}`;
      const childTo: string = to === '/' ? `/${names[i]}` : `${to}/${names[i]}`;
      this.copy(childFrom, childTo);
    }
  }

  readlink(path: string): string {
    return '';
  }
}
