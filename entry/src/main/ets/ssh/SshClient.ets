/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Thin async wrapper over libterminal_core.so. Every network step runs on the
 * native worker thread; this class only marshals bytes and JSON.
 */

import {
  connect as sshConnect,
  authPassword as sshAuthPassword,
  authKey as sshAuthKey,
  startShell as sshStartShell,
  write as sshWrite,
  read as sshRead,
  readStderr as sshReadStderr,
  resize as sshResize,
  isEof as sshIsEof,
  exitStatus as sshExitStatus,
  close as sshClose,
  openSftp as sshOpenSftp,
  sftpList as sshSftpList,
  sftpStat as sshSftpStat,
  sftpRealpath as sshSftpRealpath,
  sftpMkdir as sshSftpMkdir,
  sftpRmdir as sshSftpRmdir,
  sftpUnlink as sshSftpUnlink,
  sftpRename as sshSftpRename,
  sftpDownload as sshSftpDownload,
  sftpUpload as sshSftpUpload,
  cancelTransfers as sshCancelTransfers
} from 'libterminal_core.so';
import { FileEntry } from '../core/fs/FileEntry';
import { JsonObj, parseJson, getStr, getNum, getArr } from '../common/JsonReader';

/** Host key differs from the pinned fingerprint. Carries the new one. */
export class HostKeyError extends Error {
  fingerprint: string;
  hostKeyType: string;
  banner: string;

  constructor(fingerprint: string, hostKeyType: string, banner: string) {
    super(`host key mismatch: ${fingerprint}`);
    this.fingerprint = fingerprint;
    this.hostKeyType = hostKeyType;
    this.banner = banner;
  }
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function joinRemote(dir: string, name: string): string {
  if (dir === '/' || dir.length === 0) {
    return '/' + name;
  }
  return dir.endsWith('/') ? dir + name : dir + '/' + name;
}

function entryFrom(obj: JsonObj, dir: string): FileEntry {
  const type: string = getStr(obj, 'type');
  const name: string = getStr(obj, 'name');
  return new FileEntry(name, joinRemote(dir, name), type === 'd', type === 'l',
    getNum(obj, 'size'), getNum(obj, 'mtime'), getNum(obj, 'mode'),
    getNum(obj, 'uid'), getNum(obj, 'gid'), getStr(obj, 'target'),
    getStr(obj, 'long'), 'remote');
}

export class SshConnection {
  id: number = 0;
  host: string = '';
  port: number = 22;
  hostKeyType: string = '';
  fingerprint: string = '';
  banner: string = '';
  connected: boolean = false;
  sftpOpen: boolean = false;

  /** Performs the TCP handshake and returns the SHA-256 host key fingerprint. */
  async open(host: string, port: number, timeoutMs: number): Promise<string> {
    const raw: string = await sshConnect(host, port, timeoutMs);
    const obj: JsonObj | null = parseJson(raw);
    if (obj === null) {
      throw new Error('malformed connect response');
    }
    this.id = getNum(obj, 'id');
    this.host = host;
    this.port = port;
    this.hostKeyType = getStr(obj, 'hostKeyType');
    this.fingerprint = getStr(obj, 'fingerprint');
    this.banner = getStr(obj, 'banner');
    this.connected = true;
    return this.fingerprint;
  }

  async authPassword(user: string, password: string): Promise<void> {
    await sshAuthPassword(this.id, user, password);
  }

  async authKey(user: string, publicKeyPath: string,
                privateKeyPath: string, passphrase: string): Promise<void> {
    await sshAuthKey(this.id, user, publicKeyPath, privateKeyPath, passphrase);
  }

  async openSftpChannel(): Promise<string> {
    await sshOpenSftp(this.id);
    this.sftpOpen = true;
    return await sshSftpRealpath(this.id, '.');
  }

  async startShell(cols: number, rows: number): Promise<void> {
    await sshStartShell(this.id, cols, rows);
  }

  read(maxBytes: number): Uint8Array {
    return new Uint8Array(sshRead(this.id, maxBytes));
  }

  readStderr(maxBytes: number): Uint8Array {
    return new Uint8Array(sshReadStderr(this.id, maxBytes));
  }

  writeBytes(bytes: Uint8Array): void {
    let offset: number = 0;
    while (offset < bytes.length) {
      const chunk: Uint8Array = bytes.subarray(offset);
      const accepted: number = sshWrite(this.id, toArrayBuffer(chunk));
      if (accepted <= 0) {
        break;
      }
      offset += accepted;
    }
  }

  resize(cols: number, rows: number): void {
    sshResize(this.id, cols, rows);
  }

  isEof(): boolean {
    return sshIsEof(this.id);
  }

  exitStatus(): number {
    return sshExitStatus(this.id);
  }

  close(): boolean {
    const closed: boolean = sshClose(this.id);
    if (closed) {
      this.connected = false;
      this.sftpOpen = false;
    }
    return closed;
  }

  // --- SFTP -------------------------------------------------------------

  async list(path: string): Promise<Array<FileEntry>> {
    const raw: string = await sshSftpList(this.id, path);
    const obj: JsonObj | null = parseJson(raw);
    const entries: Array<Object> | null = obj === null ? null : getArr(obj, 'entries');
    const out: Array<FileEntry> = [];
    if (entries === null) {
      return out;
    }
    for (let i = 0; i < entries.length; i++) {
      const item: Object = entries[i];
      if (item !== null && typeof item === 'object') {
        out.push(entryFrom(item as JsonObj, path));
      }
    }
    return out;
  }

  async stat(path: string, follow: boolean): Promise<FileEntry> {
    const raw: string = await sshSftpStat(this.id, path, follow);
    const obj: JsonObj | null = parseJson(raw);
    if (obj === null) {
      throw new Error('malformed stat response');
    }
    return entryFrom(obj, '');
  }

  async realpath(path: string): Promise<string> {
    return sshSftpRealpath(this.id, path);
  }

  async mkdir(path: string, mode: number): Promise<void> {
    await sshSftpMkdir(this.id, path, mode);
  }

  async rmdir(path: string): Promise<void> {
    await sshSftpRmdir(this.id, path);
  }

  async unlink(path: string): Promise<void> {
    await sshSftpUnlink(this.id, path);
  }

  async rename(from: string, to: string): Promise<void> {
    await sshSftpRename(this.id, from, to);
  }

  async download(remote: string, local: string): Promise<number> {
    return sshSftpDownload(this.id, remote, local);
  }

  async upload(local: string, remote: string): Promise<number> {
    return sshSftpUpload(this.id, local, remote);
  }

  cancelTransfers(cancel: boolean): void {
    sshCancelTransfers(cancel);
  }
}

/** Convenience wrapper used by the two-pane file browser. */
export class SftpClient {
  private conn: SshConnection;
  home: string;

  constructor(conn: SshConnection, home: string) {
    this.conn = conn;
    this.home = home;
  }

  list(path: string): Promise<Array<FileEntry>> {
    return this.conn.list(path);
  }

  stat(path: string, follow: boolean): Promise<FileEntry> {
    return this.conn.stat(path, follow);
  }

  mkdir(path: string): Promise<void> {
    return this.conn.mkdir(path, 0o755);
  }

  rmdir(path: string): Promise<void> {
    return this.conn.rmdir(path);
  }

  unlink(path: string): Promise<void> {
    return this.conn.unlink(path);
  }

  rename(from: string, to: string): Promise<void> {
    return this.conn.rename(from, to);
  }

  download(remote: string, local: string): Promise<number> {
    return this.conn.download(remote, local);
  }

  upload(local: string, remote: string): Promise<number> {
    return this.conn.upload(local, remote);
  }

  cancel(cancel: boolean): void {
    this.conn.cancelTransfers(cancel);
  }
}
