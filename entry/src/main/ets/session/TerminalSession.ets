/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { VtScreen } from '../core/ansi/VtScreen';
import { KeyEncoder, asciiBytes, utf8Encode } from '../core/ansi/Keys';
import { Completion } from '../core/shell/Shell';
import { SftpClient } from '../ssh/SshClient';

/** Common surface the terminal view drives; local and SSH back it. */
export abstract class TerminalSession {
  screen: VtScreen = new VtScreen(80, 24);
  keys: KeyEncoder = new KeyEncoder();
  title: string = '';
  status: string = '';
  closed: boolean = false;

  abstract sendLine(text: string): void;
  abstract sendKey(name: string): void;
  abstract sendControl(key: string): void;
  abstract sendPaste(text: string): void;
  abstract resize(cols: number, rows: number): void;
  abstract close(): void;

  pump(): void {
  }

  historyPrev(): string | null {
    return null;
  }

  historyNext(): string | null {
    return null;
  }

  completeLine(line: string, caret: number): Completion | null {
    return null;
  }

  sftp(): SftpClient | null {
    return null;
  }

  kind(): string {
    return 'local';
  }

  hostLabel(): string {
    return '';
  }

  feedText(text: string): void {
    this.screen.feed(utf8Encode(text));
  }

  feedLine(text: string): void {
    this.screen.feed(utf8Encode(text));
    this.screen.feed(asciiBytes('\r\n'));
  }
}
