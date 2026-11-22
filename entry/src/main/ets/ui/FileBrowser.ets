/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Two-pane file browser: sandbox on the left, SFTP on the right, with
 * recursive copy in both directions. Files transfer with the native
 * upload/download; directories are walked and merged.
 */

import promptAction from '@ohos.promptAction';
import { FileEntry } from '../core/fs/FileEntry';
import { joinPath } from '../core/fs/PathUtil';
import { LocalFs } from '../fs/LocalFs';
import { SftpClient } from '../ssh/SshClient';
import { FilePane } from './FilePane';

@Component
export struct FileBrowser {
  localFs: LocalFs | null = null;
  sftp: SftpClient | null = null;
  @Prop remoteVersion: number = 0;

  @State localCwd: string = '/';
  @State remoteCwd: string = '';
  @State localSel: FileEntry | null = null;
  @State remoteSel: FileEntry | null = null;
  @State localTick: number = 0;
  @State remoteTick: number = 0;
  @State busy: boolean = false;
  @State message: string = '';

  private remoteRoot(): string {
    if (this.remoteCwd.length > 0) {
      return this.remoteCwd;
    }
    if (this.sftp !== null && this.sftp.home.length > 0) {
      return this.sftp.home;
    }
    return '/';
  }

  private async copyEntryToRemote(entry: FileEntry, dest: string,
                                  client: SftpClient, local: LocalFs): Promise<number> {
    if (!entry.isDir) {
      await client.upload(local.real(entry.path), dest);
      return 1;
    }
    try {
      await client.mkdir(dest);
    } catch (alreadyThere) {
      // merge into the existing directory
    }
    let count: number = 1;
    const children: Array<FileEntry> = local.list(entry.path);
    for (let i = 0; i < children.length; i++) {
      count += await this.copyEntryToRemote(children[i], joinPath(dest, children[i].name),
        client, local);
    }
    return count;
  }

  private async copyEntryToLocal(entry: FileEntry, dest: string,
                                 client: SftpClient, local: LocalFs): Promise<number> {
    if (!entry.isDir) {
      await client.download(entry.path, local.real(dest));
      return 1;
    }
    try {
      local.mkdir(dest);
    } catch (alreadyThere) {
      // merge into the existing directory
    }
    let count: number = 1;
    const children: Array<FileEntry> = await client.list(entry.path);
    for (let i = 0; i < children.length; i++) {
      count += await this.copyEntryToLocal(children[i], joinPath(dest, children[i].name),
        client, local);
    }
    return count;
  }

  private copyLocalToRemote(): void {
    const entry: FileEntry | null = this.localSel;
    const client: SftpClient | null = this.sftp;
    const local: LocalFs | null = this.localFs;
    if (entry === null || client === null || local === null) {
      promptAction.showToast({ message: 'Select a local entry and connect a host first' });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.message = `Uploading ${entry.name}…`;
    const dest: string = joinPath(this.remoteRoot(), entry.name);
    this.copyEntryToRemote(entry, dest, client, local).then((count: number): void => {
      this.busy = false;
      this.message = `Uploaded ${count} item(s) to ${this.remoteRoot()}`;
      this.remoteTick++;
    }).catch((err: Error): void => {
      this.busy = false;
      this.message = `Upload failed: ${err.message}`;
    });
  }

  private copyRemoteToLocal(): void {
    const entry: FileEntry | null = this.remoteSel;
    const client: SftpClient | null = this.sftp;
    const local: LocalFs | null = this.localFs;
    if (entry === null || client === null || local === null) {
      promptAction.showToast({ message: 'Select a remote entry and connect a host first' });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.message = `Downloading ${entry.name}…`;
    const dest: string = joinPath(this.localCwd, entry.name);
    this.copyEntryToLocal(entry, dest, client, local).then((count: number): void => {
      this.busy = false;
      this.message = `Downloaded ${count} item(s) to ${this.localCwd}`;
      this.localTick++;
    }).catch((err: Error): void => {
      this.busy = false;
      this.message = `Download failed: ${err.message}`;
    });
  }

  private cancel(): void {
    if (this.sftp !== null) {
      this.sftp.cancel(true);
      this.message = 'Transfer cancelled';
      this.busy = false;
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Button('Local → Remote')
          .height(30)
          .fontSize(11)
          .backgroundColor('#3d59a1')
          .fontColor('#ffffff')
          .borderRadius(6)
          .onClick((): void => {
            this.copyLocalToRemote();
          })
        Button('Remote → Local')
          .height(30)
          .fontSize(11)
          .backgroundColor('#5a3d7a')
          .fontColor('#ffffff')
          .borderRadius(6)
          .onClick((): void => {
            this.copyRemoteToLocal();
          })
        if (this.busy) {
          Button('Cancel')
            .height(30)
            .fontSize(11)
            .backgroundColor('#7a3d3d')
            .fontColor('#ffffff')
            .borderRadius(6)
            .onClick((): void => {
              this.cancel();
            })
        }
        Text(this.message)
          .fontSize(10)
          .fontColor('#8a93a8')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6 })

      Row({ space: 6 }) {
        Column() {
          FilePane({
            path: this.localCwd,
            selected: this.localSel,
            tick: this.localTick,
            localFs: this.localFs,
            sftp: null,
            isRemote: false,
            paneTitle: 'sandbox'
          })
        }
        .layoutWeight(1)
        .height('100%')

        Column() {
          FilePane({
            path: this.remoteCwd,
            selected: this.remoteSel,
            tick: this.remoteVersion * 1000 + this.remoteTick,
            localFs: null,
            sftp: this.sftp,
            isRemote: true,
            paneTitle: this.sftp === null ? 'no session' : this.sftp.home
          })
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 8, right: 8, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1b2030')
  }
}
