/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Local filesystem adapter: maps the virtual root '/' onto the application
 * sandbox directory, plus the public Download and Documents directories when
 * its storage permissions are granted. Normalising every path before mapping
 * keeps the shell from escaping through '..'.
 */

import fs from '@ohos.file.fs';
import Environment from '@ohos.file.environment';
import { FileEntry } from '../core/fs/FileEntry';
import { ShellFs } from '../core/shell/Shell';
import { normalizePath } from '../core/fs/PathUtil';

class Mount {
  path: string;
  root: string;

  constructor(path: string, root: string) {
    this.path = path;
    this.root = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  }
}

export class LocalFs implements ShellFs {
  cwd: string = '/';
  private baseDir: string;
  private mounts: Array<Mount> = [];

  constructor(baseDir: string) {
    this.baseDir = baseDir.endsWith('/')
      ? baseDir.substring(0, baseDir.length - 1) : baseDir;
    this.initMounts();
  }

  private initMounts(): void {
    try {
      this.mounts.push(new Mount('/download', Environment.getUserDownloadDir()));
    } catch (e) {
      // Permission denied or unsupported device: keep the mount hidden.
    }
    try {
      this.mounts.push(new Mount('/documents', Environment.getUserDocumentDir()));
    } catch (e) {
      // ditto
    }
  }

  private mountFor(path: string): Mount | null {
    for (let i = 0; i < this.mounts.length; i++) {
      const mount: Mount = this.mounts[i];
      if (path === mount.path || path.startsWith(mount.path + '/')) {
        return mount;
      }
    }
    return null;
  }

  private mountEntry(mount: Mount): FileEntry {
    return new FileEntry(mount.path.substring(1), mount.path, true, false, 0,
      Date.now(), 0o040755, 0, 0, '', '', 'mount');
  }

  root(): string {
    return this.baseDir;
  }

  /** Virtual path -> real path (sandbox by default, mounts by prefix). */
  real(path: string): string {
    const normalized: string = normalizePath(path);
    const mount: Mount | null = this.mountFor(normalized);
    if (mount !== null) {
      const rest: string = normalized.substring(mount.path.length);
      return rest.length === 0 ? mount.root : mount.root + rest;
    }
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
    const normalized: string = normalizePath(path);
    const mount: Mount | null = this.mountFor(normalized);
    if (mount !== null && normalized === mount.path) {
      return this.mountEntry(mount);
    }
    const realPath: string = this.real(normalized);
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
    const base: string = normalizePath(path);
    if (base === '/' && this.mounts.length > 0) {
      // A mount can shadow a sandbox entry of the same name; expose the mount.
      const real: Array<FileEntry> = [];
      const names: Array<string> = fs.listFileSync(this.real('/'));
      for (let i = 0; i < names.length; i++) {
        const entry: FileEntry | null = this.stat(`/${names[i]}`);
        if (entry !== null && this.mountFor(`/${names[i]}`) === null) {
          real.push(entry);
        }
      }
      for (let i = 0; i < this.mounts.length; i++) {
        real.push(this.mountEntry(this.mounts[i]));
      }
      return real;
    }
    const names: Array<string> = fs.listFileSync(this.real(base));
    const out: Array<FileEntry> = [];
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
