/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Local sandbox session: renders shell output into the VtScreen and forwards
 * history recall and tab completion to the shell engine.
 */

import { Shell, ShellOutput, Completion } from '../core/shell/Shell';
import { asciiBytes, utf8Encode } from '../core/ansi/Keys';
import { LocalFs } from '../fs/LocalFs';
import { TerminalSession } from './TerminalSession';

export class LocalSession extends TerminalSession {
  private shell: Shell;
  private historyCursor: number = 0;

  constructor(fs: LocalFs) {
    super();
    this.title = 'Local';
    this.status = 'sandbox';
    this.shell = new Shell(fs, 'local', 'sandbox');
    this.screen.title = 'Local sandbox';
    this.feedLine('OHOS Terminal 1.0 - application sandbox shell');
    this.feedLine('Paths are confined to this app. Type "help" for builtins.');
    this.feedLine('');
    this.writePrompt();
  }

  private writePrompt(): void {
    this.screen.feed(utf8Encode(this.shell.prompt()));
  }

  sendLine(text: string): void {
    if (this.closed) {
      return;
    }
    this.screen.feed(utf8Encode(text));
    this.screen.feed(asciiBytes('\r\n'));
    const result: ShellOutput = this.shell.execute(text);
    if (result.clear) {
      this.screen.reset();
    } else {
      for (let i = 0; i < result.lines.length; i++) {
        this.feedLine(result.lines[i]);
      }
    }
    if (result.exit) {
      this.feedLine('[session ended - open a new Local tab]');
      this.closed = true;
      this.status = 'closed';
      return;
    }
    this.writePrompt();
    this.historyCursor = this.shell.history.length;
  }

  sendKey(name: string): void {
    if (name === 'escape') {
      this.screen.feed(asciiBytes('\x1b'));
    }
  }

  sendControl(key: string): void {
    if (key === 'c') {
      this.feedLine('^C');
      this.writePrompt();
    } else if (key === 'l') {
      this.screen.reset();
      this.writePrompt();
    } else if (key === 'd') {
      this.feedLine('^D');
    }
  }

  sendPaste(text: string): void {
    this.screen.feed(utf8Encode(text));
  }

  resize(cols: number, rows: number): void {
    this.screen.resize(cols, rows);
  }

  close(): void {
    this.closed = true;
    this.status = 'closed';
  }

  historyPrev(): string | null {
    if (this.shell.history.length === 0) {
      return null;
    }
    if (this.historyCursor > 0) {
      this.historyCursor--;
    }
    return this.shell.history[this.historyCursor];
  }

  historyNext(): string | null {
    if (this.historyCursor < this.shell.history.length - 1) {
      this.historyCursor++;
      return this.shell.history[this.historyCursor];
    }
    this.historyCursor = this.shell.history.length;
    return '';
  }

  completeLine(line: string, caret: number): Completion | null {
    return this.shell.complete(line, caret);
  }

  prompt(): string {
    return this.shell.prompt();
  }
}
