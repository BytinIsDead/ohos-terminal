/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * A single directory entry, normalised from either the application sandbox
 * (local pane / local shell) or SFTP attributes (remote pane).
 */

export class FileEntry {
  name: string;
  path: string;
  isDir: boolean;
  isLink: boolean;
  size: number;
  mtime: number;
  mode: number;
  uid: number;
  gid: number;
  /** Symlink target when the backend reports it (SFTP); '' otherwise. */
  linkTarget: string;
  /** ls -l style line from SFTP readdir_ex; '' for local entries. */
  longEntry: string;
  /** 'local' or 'remote'. */
  origin: string;

  constructor(name: string, path: string, isDir: boolean, isLink: boolean,
              size: number, mtime: number, mode: number, uid: number,
              gid: number, linkTarget: string, longEntry: string,
              origin: string) {
    this.name = name;
    this.path = path;
    this.isDir = isDir;
    this.isLink = isLink;
    this.size = size;
    this.mtime = mtime;
    this.mode = mode;
    this.uid = uid;
    this.gid = gid;
    this.linkTarget = linkTarget;
    this.longEntry = longEntry;
    this.origin = origin;
  }
}
