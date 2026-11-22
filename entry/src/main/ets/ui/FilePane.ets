/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * One directory pane. Works against the sandbox (LocalFs) or SFTP; shows
 * name, size, mode, owner, mtime and symlink targets, supports sorting,
 * filtering, breadcrumb navigation and directory creation.
 */

import promptAction from '@ohos.promptAction';
import { FileEntry } from '../core/fs/FileEntry';
import {
  humanSize, modeString, formatDate, sortEntries, filterEntries
} from '../core/fs/Format';
import { parentPath, pathSegments, joinPath } from '../core/fs/PathUtil';
import { LocalFs } from '../fs/LocalFs';
import { SftpClient } from '../ssh/SshClient';

@Component
export struct FilePane {
  @Link path: string;
  @Link selected: FileEntry | null;
  @Prop @Watch('onExternalChange') tick: number = 0;
  localFs: LocalFs | null = null;
  sftp: SftpClient | null = null;
  isRemote: boolean = false;
  paneTitle: string = 'Files';

  @State entries: Array<FileEntry> = [];
  @State query: string = '';
  @State sortKey: string = 'name';
  @State ascending: boolean = true;
  @State dirsFirst: boolean = true;
  @State loading: boolean = false;
  @State errorText: string = '';
  @State currentKind: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  onExternalChange(): void {
    this.refresh();
  }

  private visible(): Array<FileEntry> {
    return sortEntries(filterEntries(this.entries, this.query), this.sortKey,
      this.ascending, this.dirsFirst);
  }

  refresh(): void {
    this.resolveRoot();
    if (this.path.length === 0) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    if (this.isRemote) {
      const client: SftpClient | null = this.sftp;
      if (client === null) {
        this.entries = [];
        this.loading = false;
        this.errorText = 'No SSH session - connect from Hosts';
        return;
      }
      client.list(this.path).then((list: Array<FileEntry>): void => {
        this.entries = list;
        this.currentKind = 'remote';
        this.loading = false;
      }).catch((err: Error): void => {
        this.entries = [];
        this.errorText = err.message;
        this.loading = false;
      });
    } else {
      try {
        this.entries = this.localFs === null ? [] : this.localFs.list(this.path);
        this.currentKind = 'local';
        this.loading = false;
      } catch (err) {
        this.entries = [];
        this.errorText = (err as Error).message;
        this.loading = false;
      }
    }
  }

  private resolveRoot(): void {
    if (this.path.length > 0) {
      return;
    }
    if (this.isRemote) {
      this.path = this.sftp !== null && this.sftp.home.length > 0 ? this.sftp.home : '/';
    } else {
      this.path = '/';
    }
  }

  private open(entry: FileEntry): void {
    if (entry.isDir) {
      this.path = entry.path;
      this.selected = null;
      this.query = '';
      this.refresh();
    } else {
      this.selected = entry;
    }
  }

  private goUp(): void {
    if (this.path === '/' || this.path.length === 0) {
      return;
    }
    this.path = parentPath(this.path);
    this.selected = null;
    this.refresh();
  }

  private jumpTo(index: number): void {
    const segments: Array<string> = pathSegments(this.path);
    let built: string = '';
    for (let i = 0; i <= index && i < segments.length; i++) {
      built += '/' + segments[i];
    }
    this.path = built.length === 0 ? '/' : built;
    this.selected = null;
    this.refresh();
  }

  private newFolder(): void {
    let name: string = 'new-folder';
    let counter: number = 2;
    const existing: Array<string> = this.entries.map((entry: FileEntry): string => entry.name);
    while (existing.indexOf(name) >= 0) {
      name = `new-folder-${counter}`;
      counter++;
    }
    const target: string = joinPath(this.path, name);
    if (this.isRemote) {
      const client: SftpClient | null = this.sftp;
      if (client === null) {
        return;
      }
      client.mkdir(target).then((): void => {
        this.refresh();
      }).catch((err: Error): void => {
        promptAction.showToast({ message: err.message });
      });
    } else if (this.localFs !== null) {
      try {
        this.localFs.mkdir(target);
        this.refresh();
      } catch (err) {
        promptAction.showToast({ message: (err as Error).message });
      }
    }
  }

  private deleteSelected(): void {
    const entry: FileEntry | null = this.selected;
    if (entry === null) {
      promptAction.showToast({ message: 'Select an entry first' });
      return;
    }
    AlertDialog.show({
      title: 'Delete',
      message: `Delete ${entry.isDir ? 'directory' : 'file'} "${entry.name}"?`,
      primaryButton: {
        value: 'Cancel',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: 'Delete',
        fontColor: '#e06c75',
        action: (): void => {
          this.removeEntry(entry);
        }
      }
    });
  }

  private removeEntry(entry: FileEntry): void {
    if (this.isRemote) {
      const client: SftpClient | null = this.sftp;
      if (client === null) {
        return;
      }
      this.removeRemote(client, entry.path, entry.isDir).then((): void => {
        this.selected = null;
        this.refresh();
      }).catch((err: Error): void => {
        promptAction.showToast({ message: err.message });
      });
    } else if (this.localFs !== null) {
      try {
        this.localFs.remove(entry.path, entry.isDir);
        this.selected = null;
        this.refresh();
      } catch (err) {
        promptAction.showToast({ message: (err as Error).message });
      }
    }
  }

  private async removeRemote(client: SftpClient, path: string,
                              isDir: boolean): Promise<void> {
    if (!isDir) {
      await client.unlink(path);
      return;
    }
    const children: Array<FileEntry> = await client.list(path);
    for (let i = 0; i < children.length; i++) {
      await this.removeRemote(client, children[i].path, children[i].isDir);
    }
    await client.rmdir(path);
  }

  private cycleSort(): void {
    if (this.sortKey === 'name') {
      this.sortKey = 'size';
    } else if (this.sortKey === 'size') {
      this.sortKey = 'time';
    } else if (this.sortKey === 'time') {
      this.sortKey = 'type';
    } else {
      this.sortKey = 'name';
    }
  }

  @Builder
  smallButton(label: string, code: string) {
    Button(label)
      .height(26)
      .fontSize(11)
      .padding({ left: 8, right: 8 })
      .backgroundColor('#2b3448')
      .fontColor('#d7dce8')
      .borderRadius(5)
      .onClick((): void => {
        if (code === 'up') {
          this.goUp();
        } else if (code === 'refresh') {
          this.refresh();
        } else if (code === 'mkdir') {
          this.newFolder();
        } else if (code === 'delete') {
          this.deleteSelected();
        } else if (code === 'sort') {
          this.cycleSort();
        } else if (code === 'dirs') {
          this.dirsFirst = !this.dirsFirst;
        } else if (code === 'asc') {
          this.ascending = !this.ascending;
        } else if (code === 'root') {
          this.path = '/';
          this.selected = null;
          this.refresh();
        } else if (code.startsWith('jump')) {
          this.jumpTo(parseInt(code.substring(4), 10));
        }
      })
  }

  @Builder
  entryRow(entry: FileEntry) {
    Row({ space: 6 }) {
      Text(entry.isLink ? 'l' : (entry.isDir ? 'd' : '-'))
        .fontSize(12)
        .fontColor(entry.isDir ? '#61afef' : (entry.isLink ? '#c678dd' : '#7f8aa3'))
        .width(12)
      Column({ space: 1 }) {
        Row({ space: 4 }) {
          Text(entry.name)
            .fontSize(12)
            .fontColor(entry.isDir ? '#9ecbff' : '#d7dce8')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (entry.isLink && entry.linkTarget.length > 0) {
            Text('-> ' + entry.linkTarget)
              .fontSize(10)
              .fontColor('#c678dd')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        Text(`${modeString(entry.mode)}  ${entry.uid}:${entry.gid}  ${formatDate(entry.mtime)}`)
          .fontSize(9)
          .fontColor('#68718a')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(entry.isDir ? '-' : humanSize(entry.size))
        .fontSize(10)
        .fontColor('#aab3c5')
        .width(64)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor(this.selected !== null && this.selected.path === entry.path
      ? '#33415c' : Color.Transparent)
    .onClick((): void => {
      this.open(entry);
    })
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 6 }) {
        Text(this.isRemote ? 'REMOTE' : 'LOCAL')
          .fontSize(9)
          .fontColor(this.isRemote ? '#c678dd' : '#61afef')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor('#252c3d')
          .borderRadius(4)
        Text(this.paneTitle)
          .fontSize(11)
          .fontColor('#aab3c5')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.smallButton('↑', 'up')
        this.smallButton('⟳', 'refresh')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 4 })

      Row({ space: 3 }) {
        this.smallButton('/', 'root')
        ForEach(pathSegments(this.path), (segment: string, index: number) => {
          this.smallButton(segment, 'jump' + index)
        }, (segment: string, index: number): string => `${index}:${segment}`)
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 4 })

      Row({ space: 6 }) {
        TextInput({ text: this.query, placeholder: 'filter name' })
          .layoutWeight(1)
          .height(28)
          .fontSize(11)
          .fontColor('#d7dce8')
          .placeholderColor('#5c6579')
          .backgroundColor('#252c3d')
          .borderRadius(5)
          .onChange((value: string): void => {
            this.query = value;
          })
        this.smallButton('New', 'mkdir')
        this.smallButton('Del', 'delete')
        this.smallButton(this.sortKey + (this.ascending ? '↑' : '↓'), 'sort')
        this.smallButton(this.dirsFirst ? 'd↑' : 'mix', 'dirs')
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 4 })

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(10)
          .fontColor('#e06c75')
          .padding({ left: 8, right: 8, bottom: 4 })
          .width('100%')
      }
      if (this.loading) {
        Text('loading…')
          .fontSize(10)
          .fontColor('#7f8aa3')
          .padding({ left: 8, bottom: 4 })
      }

      List({ space: 0 }) {
        ForEach(this.visible(), (entry: FileEntry) => {
          ListItem() {
            this.entryRow(entry)
          }
        }, (entry: FileEntry): string => `${entry.path}:${entry.mtime}:${entry.size}`)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: '#252c3d' })
      .edgeEffect(EdgeEffect.Spring)

      Text(`${this.visible().length} of ${this.entries.length} entries`)
        .fontSize(9)
        .fontColor('#68718a')
        .padding({ left: 8, top: 3, bottom: 4 })
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#20263a')
    .borderRadius(8)
    .clip(true)
  }
}
