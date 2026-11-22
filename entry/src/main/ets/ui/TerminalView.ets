/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Terminal surface: a Canvas showing the emulated screen plus a line input
 * with a key bar. HarmonyOS soft keyboards do not expose raw printable key
 * events reliably, so text is typed into the field and sent on Enter, while
 * the key bar forwards editing keys, control keys and escapes. Full-screen
 * TUIs render correctly; single-key interaction is limited to the key bar.
 */

import pasteboard from '@ohos.pasteboard';
import { TerminalSession } from '../session/TerminalSession';
import { Completion } from '../core/shell/Shell';
import { TerminalPainter, TerminalMetrics } from './TerminalPainter';

@Component
export struct TerminalView {
  controller: TerminalSession | null = null;
  sessionKey: string = '';
  @State input: string = '';
  @State fontSize: number = 13;
  @State statusText: string = '';

  private painter: TerminalPainter = new TerminalPainter();
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private timer: number = -1;
  private ready: boolean = false;
  private viewW: number = 0;
  private viewH: number = 0;
  private lastCols: number = 0;
  private lastRows: number = 0;
  private lastKey: string = '';
  private needsPaint: boolean = true;

  aboutToAppear(): void {
    this.timer = setInterval((): void => {
      this.tick();
    }, 33);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private tick(): void {
    const session: TerminalSession | null = this.controller;
    if (session === null) {
      return;
    }
    if (this.sessionKey !== this.lastKey) {
      this.lastKey = this.sessionKey;
      this.lastCols = 0;
      this.lastRows = 0;
      this.needsPaint = true;
    }
    session.pump();
    if (session.screen.takeDirty()) {
      this.needsPaint = true;
    }
    if (session.status.length > 0 && session.status !== this.statusText) {
      this.statusText = session.status;
    }
    if (this.needsPaint) {
      this.redraw();
    }
  }

  private redraw(): void {
    const session: TerminalSession | null = this.controller;
    if (!this.ready || session === null || this.viewW < 40 || this.viewH < 40) {
      return;
    }
    const metrics: TerminalMetrics = this.painter.paint(this.ctx, session.screen,
      this.viewW, this.viewH, this.fontSize);
    if (metrics.cols !== this.lastCols || metrics.rows !== this.lastRows) {
      this.lastCols = metrics.cols;
      this.lastRows = metrics.rows;
      session.resize(metrics.cols, metrics.rows);
      this.painter.paint(this.ctx, session.screen, this.viewW, this.viewH, this.fontSize);
    }
    this.needsPaint = false;
  }

  private submit(): void {
    const session: TerminalSession | null = this.controller;
    if (session === null || session.closed) {
      return;
    }
    const line: string = this.input;
    this.input = '';
    session.sendLine(line);
    session.screen.scrollToBottom();
    this.needsPaint = true;
    this.redraw();
  }

  private isLocal(): boolean {
    return this.controller !== null && this.controller.kind() === 'local';
  }

  private pressTab(): void {
    const session: TerminalSession | null = this.controller;
    if (session === null) {
      return;
    }
    if (this.isLocal()) {
      const completion: Completion | null = session.completeLine(this.input, this.input.length);
      if (completion !== null) {
        this.input = completion.line;
      }
    } else {
      session.sendKey('tab');
    }
  }

  private pressPaste(): void {
    const session: TerminalSession | null = this.controller;
    if (session === null) {
      return;
    }
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData): void => {
      const text: string = data.getPrimaryText();
      if (text.length === 0) {
        return;
      }
      if (this.isLocal()) {
        this.input = this.input + text.replace(/\n/g, ' ');
      } else {
        session.sendPaste(text);
        this.needsPaint = true;
        this.redraw();
      }
    });
  }

  private scrollView(lines: number): void {
    const session: TerminalSession | null = this.controller;
    if (session === null) {
      return;
    }
    session.screen.scrollBy(lines);
    this.needsPaint = true;
    this.redraw();
  }

  private handleKey(code: string): void {
    const session: TerminalSession | null = this.controller;
    if (session === null) {
      return;
    }
    if (code === 'font-down') {
      this.fontSize = Math.max(9, this.fontSize - 1);
      this.lastCols = 0;
    } else if (code === 'font-up') {
      this.fontSize = Math.min(22, this.fontSize + 1);
      this.lastCols = 0;
    } else if (code === 'pgup') {
      this.scrollView(this.lastRows > 2 ? this.lastRows - 2 : 5);
      return;
    } else if (code === 'pgdn') {
      this.scrollView(this.lastRows > 2 ? -(this.lastRows - 2) : -5);
      return;
    } else if (code === 'tab') {
      this.pressTab();
      return;
    } else if (code === 'paste') {
      this.pressPaste();
      return;
    } else if (code === 'up' && this.isLocal()) {
      const previous: string | null = session.historyPrev();
      if (previous !== null) {
        this.input = previous;
      }
      return;
    } else if (code === 'down' && this.isLocal()) {
      const next: string | null = session.historyNext();
      if (next !== null) {
        this.input = next;
      }
      return;
    } else if (code === 'esc') {
      session.sendKey('escape');
    } else if (code === 'left') {
      session.sendKey('left');
    } else if (code === 'right') {
      session.sendKey('right');
    } else if (code === 'up') {
      session.sendKey('up');
    } else if (code === 'down') {
      session.sendKey('down');
    } else if (code === 'home') {
      session.sendKey('home');
    } else if (code === 'end') {
      session.sendKey('end');
    } else if (code === 'del') {
      session.sendKey('delete');
    } else if (code === 'c') {
      session.sendControl('c');
    } else if (code === 'd') {
      session.sendControl('d');
    } else if (code === 'l') {
      session.sendControl('l');
    } else if (code === 'z') {
      session.sendControl('z');
    }
    this.needsPaint = true;
    this.redraw();
  }

  @Builder
  keyButton(label: string, code: string, fontScale: number) {
    Button(label)
      .fontSize(12 * fontScale)
      .height(30)
      .padding({ left: 9, right: 9 })
      .backgroundColor('#2b3448')
      .fontColor('#d7dce8')
      .borderRadius(6)
      .onClick((): void => {
        this.handleKey(code);
      })
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text(this.controller === null ? 'No session'
          : (this.isLocal() ? 'local sandbox' : `ssh ${this.controller.hostLabel()}`))
          .fontSize(11)
          .fontColor('#7f8aa3')
          .layoutWeight(1)
        this.keyButton('A-', 'font-down', 1.2)
        this.keyButton('A+', 'font-up', 1.1)
        this.keyButton('PgUp', 'pgup', 1)
        this.keyButton('PgDn', 'pgdn', 1)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })

      Canvas(this.ctx)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#1b2030')
        .onReady((): void => {
          this.ready = true;
          this.needsPaint = true;
          this.redraw();
        })
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          this.viewW = Number(newArea.width);
          this.viewH = Number(newArea.height);
          this.needsPaint = true;
          this.redraw();
        })

      Row({ space: 6 }) {
        Text(this.isLocal() ? '$' : '>')
          .fontSize(13)
          .fontColor('#98c379')
        TextInput({ text: this.input, placeholder: this.isLocal()
          ? 'type a command, Enter runs it'
          : 'type a line, Enter sends it' })
          .layoutWeight(1)
          .height(38)
          .fontSize(this.fontSize)
          .fontColor('#d7dce8')
          .placeholderColor('#5c6579')
          .backgroundColor('#252c3d')
          .borderRadius(6)
          .onChange((value: string): void => {
            this.input = value;
          })
          .onSubmit((): void => {
            this.submit();
          })
        Button('Send')
          .height(38)
          .fontSize(12)
          .backgroundColor('#3d59a1')
          .fontColor('#ffffff')
          .borderRadius(6)
          .onClick((): void => {
            this.submit();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      Scroll() {
        Row({ space: 6 }) {
          this.keyButton('Esc', 'esc', 1)
          this.keyButton('Tab', 'tab', 1)
          this.keyButton('←', 'left', 1.3)
          this.keyButton('↑', 'up', 1.3)
          this.keyButton('↓', 'down', 1.3)
          this.keyButton('→', 'right', 1.3)
          this.keyButton('Home', 'home', 1)
          this.keyButton('End', 'end', 1)
          this.keyButton('Del', 'del', 1)
          this.keyButton('Paste', 'paste', 1)
          this.keyButton('C-c', 'c', 1)
          this.keyButton('C-d', 'd', 1)
          this.keyButton('C-l', 'l', 1)
          this.keyButton('C-z', 'z', 1)
        }
        .padding({ left: 8, right: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(40)
      .padding({ top: 4, bottom: 6 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1b2030')
  }
}
