/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * Type surface of libterminal_core.so: libssh2-backed SSH/SFTP transport.
 *
 * Every call that may wait on the network (connect, auth, channel setup,
 * SFTP) returns a Promise and runs on a worker thread. Channel read/write
 * are synchronous and non-blocking; an empty ArrayBuffer from read() means
 * "no data right now".
 *
 * JSON results:
 *   connect -> {"id":number,"hostKeyType":string,"fingerprint":string,"banner":string}
 *   sftpList -> {"count":number,"entries":[entry,...]}
 *   sftpStat -> entry
 *
 * entry = {"name":string,"type":"d"|"f"|"l"|"o","mode":number,"size":number,
 *          "mtime":number,"atime":number,"uid":number,"gid":number,
 *          "target":string|null,"long":string|null}
 */

export const connect: (host: string, port: number, timeoutMs: number) => Promise<string>;

export const authPassword: (id: number, user: string, password: string) => Promise<void>;

export const authKey: (id: number, user: string, publicKeyPath: string,
  privateKeyPath: string, passphrase: string) => Promise<void>;

export const startShell: (id: number, cols: number, rows: number) => Promise<void>;

export const startExec: (id: number, command: string) => Promise<void>;

/** Returns bytes accepted (may be less than requested), or -1 on error. */
export const write: (id: number, data: ArrayBuffer) => number;

export const read: (id: number, maxBytes: number) => ArrayBuffer;

export const readStderr: (id: number, maxBytes: number) => ArrayBuffer;

export const resize: (id: number, cols: number, rows: number) => void;

export const isEof: (id: number) => boolean;

/** Exit status, or -1 while the channel is still open. */
export const exitStatus: (id: number) => number;

/** Returns false when the session still has a pending worker operation. */
export const close: (id: number) => boolean;

export const openSftp: (id: number) => Promise<void>;

export const sftpList: (id: number, path: string) => Promise<string>;

export const sftpStat: (id: number, path: string, follow: boolean) => Promise<string>;

/** Resolves an absolute remote path (e.g. "." -> "/home/user"). */
export const sftpRealpath: (id: number, path: string) => Promise<string>;

export const sftpMkdir: (id: number, path: string, mode: number) => Promise<void>;

export const sftpRmdir: (id: number, path: string) => Promise<void>;

export const sftpUnlink: (id: number, path: string) => Promise<void>;

export const sftpRename: (id: number, from: string, to: string) => Promise<void>;

/** Downloads remote -> local. Resolves with the number of bytes written. */
export const sftpDownload: (id: number, remotePath: string, localPath: string) => Promise<number>;

/** Uploads local -> remote. Resolves with the number of bytes sent. */
export const sftpUpload: (id: number, localPath: string, remotePath: string) => Promise<number>;

export const cancelTransfers: (cancel: boolean) => void;
