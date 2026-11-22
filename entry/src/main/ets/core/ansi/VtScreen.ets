/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * VT100/xterm screen model and parser.
 *
 * Pure TypeScript: no OHOS APIs, no third-party code. The parser handles the
 * subset of ECMA-48 that real shells and TUI programs emit: UTF-8 text,
 * cursor movement, erase/insert/delete, scroll regions, SGR colours (16/256/
 * truecolour), alternate screen, deferred autowrap, titles, device status
 * reports and bracketed paste. Unknown sequences are consumed and ignored.
 */

export const VT_FG_DEFAULT: number = -1;
/** Truecolour marker: value = 0x1000000 | (r << 16) | (g << 8) | b. */
export const VT_TRUE_COLOR: number = 0x1000000;

export const VT_BOLD: number = 1;
export const VT_ITALIC: number = 2;
export const VT_UNDERLINE: number = 4;
export const VT_INVERSE: number = 8;
export const VT_DIM: number = 16;
export const VT_STRIKE: number = 32;

export class VtCell {
  ch: string;
  fg: number;
  bg: number;
  flags: number;

  constructor(ch: string = ' ', fg: number = VT_FG_DEFAULT,
              bg: number = VT_FG_DEFAULT, flags: number = 0) {
    this.ch = ch;
    this.fg = fg;
    this.bg = bg;
    this.flags = flags;
  }

  clone(): VtCell {
    return new VtCell(this.ch, this.fg, this.bg, this.flags);
  }
}

export class VtCursor {
  row: number;
  col: number;
  visible: boolean;

  constructor(row: number, col: number, visible: boolean) {
    this.row = row;
    this.col = col;
    this.visible = visible;
  }
}

function blankLine(cols: number, bg: number): Array<VtCell> {
  const line: Array<VtCell> = [];
  for (let i = 0; i < cols; i++) {
    line.push(new VtCell(' ', VT_FG_DEFAULT, bg, 0));
  }
  return line;
}

function copyLine(line: Array<VtCell>, cols: number): Array<VtCell> {
  const out: Array<VtCell> = [];
  for (let i = 0; i < cols; i++) {
    out.push(i < line.length ? line[i].clone() : new VtCell(' ', VT_FG_DEFAULT, VT_FG_DEFAULT, 0));
  }
  return out;
}

/** Display width in terminal cells (0 combining, 2 wide East Asian). */
export function charWidth(cp: number): number {
  if (cp === 0) {
    return 0;
  }
  if ((cp >= 0x0300 && cp <= 0x036f) || (cp >= 0x200b && cp <= 0x200f) ||
      (cp >= 0x20d0 && cp <= 0x20ff) || (cp >= 0xfe00 && cp <= 0xfe0f) ||
      (cp >= 0xfe20 && cp <= 0xfe2f)) {
    return 0;
  }
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1f64f) ||
      (cp >= 0x1f900 && cp <= 0x1f9ff) || (cp >= 0x20000 && cp <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

function codePointToString(cp: number): string {
  if (cp <= 0xffff) {
    return String.fromCharCode(cp);
  }
  const adjusted: number = cp - 0x10000;
  const high: number = 0xd800 + (adjusted >> 10);
  const low: number = 0xdc00 + (adjusted & 0x3ff);
  return String.fromCharCode(high) + String.fromCharCode(low);
}

const STATE_GROUND: number = 0;
const STATE_ESC: number = 1;
const STATE_CSI: number = 2;
const STATE_OSC: number = 3;
const STATE_OSC_ESC: number = 4;
const STATE_STRING: number = 5;
const STATE_STRING_ESC: number = 6;
const STATE_CHARSET: number = 7;

const MAX_RESPONSE_QUEUE: number = 16;
const MAX_OSC: number = 4096;

export class VtScreen {
  cols: number;
  rows: number;
  title: string = '';
  bracketedPaste: boolean = false;
  applicationCursorKeys: boolean = false;
  cursorVisible: boolean = true;

  private grid: Array<Array<VtCell>> = [];
  private scrollback: Array<Array<VtCell>> = [];
  private maxScrollback: number = 2000;
  private cursorRow: number = 0;
  private cursorCol: number = 0;
  private savedRow: number = 0;
  private savedCol: number = 0;
  private savedFg: number = VT_FG_DEFAULT;
  private savedBg: number = VT_FG_DEFAULT;
  private savedFlags: number = 0;
  private attrFg: number = VT_FG_DEFAULT;
  private attrBg: number = VT_FG_DEFAULT;
  private attrFlags: number = 0;
  private scrollTop: number = 0;
  private scrollBottom: number = 0;
  private autowrap: boolean = true;
  private insertMode: boolean = false;
  private wrapPending: boolean = false;
  private altActive: boolean = false;
  private altSavedGrid: Array<Array<VtCell>> = [];
  private altSavedRow: number = 0;
  private altSavedCol: number = 0;
  private viewportOffset: number = 0;
  private responses: Array<string> = [];
  private bellPending: boolean = false;
  private dirty: boolean = true;

  private state: number = STATE_GROUND;
  private csiParams: Array<number> = [];
  private csiCurrent: number = -1;
  private csiPrefix: string = '';
  private csiInter: string = '';
  private oscBuf: string = '';
  private utfNeed: number = 0;
  private utfCode: number = 0;
  private utfMin: number = 0;

  constructor(cols: number = 80, rows: number = 24) {
    this.cols = cols > 0 ? cols : 80;
    this.rows = rows > 0 ? rows : 24;
    this.scrollBottom = this.rows - 1;
    this.reset();
  }

  reset(): void {
    this.grid = [];
    for (let i = 0; i < this.rows; i++) {
      this.grid.push(blankLine(this.cols, VT_FG_DEFAULT));
    }
    this.scrollback = [];
    this.cursorRow = 0;
    this.cursorCol = 0;
    this.savedRow = 0;
    this.savedCol = 0;
    this.attrFg = VT_FG_DEFAULT;
    this.attrBg = VT_FG_DEFAULT;
    this.attrFlags = 0;
    this.scrollTop = 0;
    this.scrollBottom = this.rows - 1;
    this.autowrap = true;
    this.insertMode = false;
    this.wrapPending = false;
    this.altActive = false;
    this.altSavedGrid = [];
    this.viewportOffset = 0;
    this.responses = [];
    this.bellPending = false;
    this.state = STATE_GROUND;
    this.csiParams = [];
    this.csiCurrent = -1;
    this.csiPrefix = '';
    this.csiInter = '';
    this.utfNeed = 0;
    this.utfCode = 0;
    this.utfMin = 0;
    this.title = '';
    this.bracketedPaste = false;
    this.applicationCursorKeys = false;
    this.cursorVisible = true;
    this.dirty = true;
  }

  // ------------------------------------------------------------------ parser

  feed(bytes: Uint8Array): void {
    for (let i = 0; i < bytes.length; i++) {
      this.feedByte(bytes[i] & 0xff);
    }
  }

  /** Writes plain text (no escape processing) at the cursor. */
  writeText(text: string): void {
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code === 0x0a) {
        this.linefeed();
      } else if (code === 0x0d) {
        this.carriageReturn();
      } else if (code === 0x09) {
        this.tabForward(1);
      } else if (code >= 0x20) {
        if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
          const low: number = text.charCodeAt(i + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            const cp: number = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
            this.putCodePoint(cp);
            i++;
            continue;
          }
        }
        this.putCodePoint(code);
      }
    }
  }

  private feedByte(byte: number): void {
    if (this.state === STATE_GROUND) {
      if (byte < 0x20) {
        this.control(byte);
        return;
      }
      if (byte === 0x7f) {
        return;
      }
      if (byte < 0x80) {
        this.putCodePoint(byte);
        return;
      }
      this.utf8Byte(byte);
      return;
    }
    if (this.state === STATE_ESC) {
      this.escape(byte);
      return;
    }
    if (this.state === STATE_CSI) {
      this.csiByte(byte);
      return;
    }
    if (this.state === STATE_OSC) {
      if (byte === 0x07) {
        this.finishOsc();
      } else if (byte === 0x1b) {
        this.state = STATE_OSC_ESC;
      } else if (this.oscBuf.length < MAX_OSC) {
        this.oscBuf += String.fromCharCode(byte);
      }
      return;
    }
    if (this.state === STATE_OSC_ESC) {
      if (byte === 0x5c) {
        this.finishOsc();
      } else {
        this.state = STATE_GROUND;
      }
      return;
    }
    if (this.state === STATE_STRING) {
      if (byte === 0x1b) {
        this.state = STATE_STRING_ESC;
      }
      return;
    }
    if (this.state === STATE_STRING_ESC) {
      this.state = byte === 0x5c ? STATE_GROUND : STATE_STRING;
      return;
    }
    if (this.state === STATE_CHARSET) {
      this.state = STATE_GROUND;
      return;
    }
  }

  private control(byte: number): void {
    this.wrapPending = false;
    if (byte === 0x07) {
      this.bellPending = true;
    } else if (byte === 0x08) {
      if (this.cursorCol > 0) {
        this.cursorCol--;
      }
    } else if (byte === 0x09) {
      this.tabForward(1);
    } else if (byte === 0x0a || byte === 0x0b || byte === 0x0c) {
      this.linefeed();
    } else if (byte === 0x0d) {
      this.carriageReturn();
    } else if (byte === 0x1b) {
      this.state = STATE_ESC;
    }
  }

  private utf8Byte(byte: number): void {
    if (this.utfNeed > 0) {
      if ((byte & 0xc0) === 0x80) {
        this.utfCode = (this.utfCode << 6) | (byte & 0x3f);
        this.utfNeed--;
        if (this.utfNeed === 0) {
          let cp: number = this.utfCode;
          if (cp < this.utfMin || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
            cp = 0xfffd;
          }
          this.utfCode = 0;
          this.putCodePoint(cp);
        }
        return;
      }
      this.utfNeed = 0;
      this.utfCode = 0;
      this.putCodePoint(0xfffd);
    }
    if (byte >= 0xc2 && byte <= 0xdf) {
      this.utfNeed = 1;
      this.utfCode = byte & 0x1f;
      this.utfMin = 0x80;
    } else if (byte >= 0xe0 && byte <= 0xef) {
      this.utfNeed = 2;
      this.utfCode = byte & 0x0f;
      this.utfMin = 0x800;
    } else if (byte >= 0xf0 && byte <= 0xf4) {
      this.utfNeed = 3;
      this.utfCode = byte & 0x07;
      this.utfMin = 0x10000;
    } else {
      this.putCodePoint(0xfffd);
    }
  }

  private putCodePoint(cp: number): void {
    if (cp === 0x0a) {
      this.linefeed();
      return;
    }
    if (cp === 0x0d) {
      this.carriageReturn();
      return;
    }
    const width: number = charWidth(cp);
    if (width === 0) {
      let col: number = this.cursorCol - 1;
      if (this.wrapPending) {
        col = this.cursorCol;
      }
      if (col >= 0 && col < this.cols) {
        this.grid[this.cursorRow][col].ch += codePointToString(cp);
        this.dirty = true;
      }
      return;
    }
    if (this.wrapPending) {
      this.wrapPending = false;
      this.carriageReturn();
      this.linefeed();
    }
    if (this.cursorCol + width > this.cols) {
      if (this.autowrap) {
        this.carriageReturn();
        this.linefeed();
      } else {
        this.cursorCol = this.cols - width;
        if (this.cursorCol < 0) {
          this.cursorCol = 0;
        }
      }
    }
    if (this.insertMode) {
      const line: Array<VtCell> = this.grid[this.cursorRow];
      for (let i = this.cols - 1; i >= this.cursorCol + width; i--) {
        line[i] = line[i - width];
      }
      for (let i = 0; i < width; i++) {
        line[this.cursorCol + i] = new VtCell(' ', this.attrFg, this.attrBg, this.attrFlags);
      }
    }
    const row: Array<VtCell> = this.grid[this.cursorRow];
    row[this.cursorCol] = new VtCell(codePointToString(cp), this.attrFg,
                                     this.attrBg, this.attrFlags);
    if (width === 2 && this.cursorCol + 1 < this.cols) {
      row[this.cursorCol + 1] = new VtCell('', this.attrFg, this.attrBg, this.attrFlags);
    }
    this.cursorCol += width;
    if (this.cursorCol >= this.cols) {
      this.cursorCol = this.cols - 1;
      if (this.autowrap) {
        this.wrapPending = true;
      }
    }
    this.viewportOffset = 0;
    this.dirty = true;
  }

  private escape(byte: number): void {
    if (byte === 0x5b) {
      this.state = STATE_CSI;
      this.csiParams = [];
      this.csiCurrent = -1;
      this.csiPrefix = '';
      this.csiInter = '';
      return;
    }
    if (byte === 0x5d) {
      this.state = STATE_OSC;
      this.oscBuf = '';
      return;
    }
    if (byte === 0x50 || byte === 0x58 || byte === 0x5e || byte === 0x5f) {
      this.state = STATE_STRING;
      return;
    }
    if (byte === 0x28 || byte === 0x29 || byte === 0x2a || byte === 0x2b) {
      this.state = STATE_CHARSET;
      return;
    }
    this.state = STATE_GROUND;
    if (byte === 0x37) {
      this.saveCursor();
    } else if (byte === 0x38) {
      this.restoreCursor();
    } else if (byte === 0x44) {
      this.linefeed();
    } else if (byte === 0x45) {
      this.carriageReturn();
      this.linefeed();
    } else if (byte === 0x4d) {
      this.reverseIndex();
    } else if (byte === 0x63) {
      this.reset();
    } else if (byte === 0x3d || byte === 0x3e) {
      // keypad modes: unused
    }
  }

  private finishOsc(): void {
    this.state = STATE_GROUND;
    const parts: Array<string> = this.oscBuf.split(';');
    if (parts.length >= 2) {
      const code: string = parts[0];
      if (code === '0' || code === '1' || code === '2') {
        let title: string = '';
        for (let i = 1; i < parts.length; i++) {
          if (i > 1) {
            title += ';';
          }
          title += parts[i];
        }
        this.title = title;
      }
    }
    this.oscBuf = '';
  }

  private csiByte(byte: number): void {
    if (byte >= 0x30 && byte <= 0x39) {
      if (this.csiCurrent < 0) {
        this.csiCurrent = 0;
      }
      if (this.csiCurrent < 100000) {
        this.csiCurrent = this.csiCurrent * 10 + (byte - 0x30);
      }
      return;
    }
    if (byte === 0x3b || byte === 0x3a) {
      this.csiParams.push(this.csiCurrent < 0 ? 0 : this.csiCurrent);
      this.csiCurrent = -1;
      return;
    }
    if (byte >= 0x3c && byte <= 0x3f && this.csiParams.length === 0 &&
        this.csiCurrent < 0 && this.csiPrefix.length === 0) {
      this.csiPrefix = String.fromCharCode(byte);
      return;
    }
    if (byte >= 0x20 && byte <= 0x2f) {
      this.csiInter += String.fromCharCode(byte);
      return;
    }
    if (byte >= 0x40 && byte <= 0x7e) {
      this.csiParams.push(this.csiCurrent < 0 ? 0 : this.csiCurrent);
      this.csiCurrent = -1;
      this.state = STATE_GROUND;
      this.csiDispatch(String.fromCharCode(byte));
      return;
    }
    this.state = STATE_GROUND;
  }

  private param(index: number, def: number): number {
    if (index >= this.csiParams.length) {
      return def;
    }
    const value: number = this.csiParams[index];
    return value > 0 ? value : def;
  }

  private csiDispatch(finalChar: string): void {
    const p0: number = this.csiParams.length > 0 ? this.csiParams[0] : 0;
    if (finalChar === 'A') {
      this.moveRow(-this.param(0, 1));
    } else if (finalChar === 'B' || finalChar === 'e') {
      this.moveRow(this.param(0, 1));
    } else if (finalChar === 'C' || finalChar === 'a') {
      this.moveCol(this.param(0, 1));
    } else if (finalChar === 'D') {
      this.moveCol(-this.param(0, 1));
    } else if (finalChar === 'E') {
      this.moveRow(this.param(0, 1));
      this.cursorCol = 0;
    } else if (finalChar === 'F') {
      this.moveRow(-this.param(0, 1));
      this.cursorCol = 0;
    } else if (finalChar === 'G' || finalChar === '`') {
      this.cursorCol = Math.min(this.param(0, 1) - 1, this.cols - 1);
    } else if (finalChar === 'H' || finalChar === 'f') {
      this.cursorRow = Math.min(this.param(0, 1) - 1, this.rows - 1);
      this.cursorCol = Math.min(this.param(1, 1) - 1, this.cols - 1);
      this.wrapPending = false;
    } else if (finalChar === 'd') {
      this.cursorRow = Math.min(this.param(0, 1) - 1, this.rows - 1);
    } else if (finalChar === 'J') {
      this.eraseDisplay(p0);
    } else if (finalChar === 'K') {
      this.eraseLine(p0);
    } else if (finalChar === 'L') {
      this.insertLines(this.param(0, 1));
    } else if (finalChar === 'M') {
      this.deleteLines(this.param(0, 1));
    } else if (finalChar === 'P') {
      this.deleteChars(this.param(0, 1));
    } else if (finalChar === '@') {
      this.insertChars(this.param(0, 1));
    } else if (finalChar === 'X') {
      this.eraseChars(this.param(0, 1));
    } else if (finalChar === 'S') {
      this.scrollUp(this.param(0, 1));
    } else if (finalChar === 'T') {
      this.scrollDown(this.param(0, 1));
    } else if (finalChar === 'r') {
      this.setScrollRegion(this.param(0, 1), this.param(1, this.rows));
    } else if (finalChar === 'm') {
      this.sgr();
    } else if (finalChar === 'h' || finalChar === 'l') {
      this.setModes(finalChar === 'h');
    } else if (finalChar === 's') {
      this.saveCursor();
    } else if (finalChar === 'u') {
      this.restoreCursor();
    } else if (finalChar === 'n') {
      this.deviceStatus(p0);
    } else if (finalChar === 'c') {
      this.responses.push('\x1b[?6c');
    } else if (finalChar === 't') {
      if (p0 === 18) {
        this.responses.push(`\x1b[8;${this.rows};${this.cols}t`);
      }
    }
  }

  private setModes(enabled: boolean): void {
    if (this.csiPrefix === '?') {
      for (let i = 0; i < this.csiParams.length; i++) {
        const mode: number = this.csiParams[i];
        if (mode === 1) {
          this.applicationCursorKeys = enabled;
        } else if (mode === 4) {
          this.insertMode = enabled;
        } else if (mode === 7) {
          this.autowrap = enabled;
        } else if (mode === 25) {
          this.cursorVisible = enabled;
        } else if (mode === 1049 || mode === 1047 || mode === 47) {
          this.setAltScreen(enabled);
        } else if (mode === 2004) {
          this.bracketedPaste = enabled;
        }
      }
    }
  }

  private setAltScreen(enabled: boolean): void {
    if (enabled && !this.altActive) {
      this.altActive = true;
      this.altSavedGrid = this.grid;
      this.altSavedRow = this.cursorRow;
      this.altSavedCol = this.cursorCol;
      this.grid = [];
      for (let i = 0; i < this.rows; i++) {
        this.grid.push(blankLine(this.cols, this.attrBg));
      }
      this.cursorRow = 0;
      this.cursorCol = 0;
    } else if (!enabled && this.altActive) {
      this.altActive = false;
      this.grid = this.altSavedGrid;
      this.altSavedGrid = [];
      this.cursorRow = Math.min(this.altSavedRow, this.rows - 1);
      this.cursorCol = Math.min(this.altSavedCol, this.cols - 1);
    }
    this.wrapPending = false;
    this.viewportOffset = 0;
    this.dirty = true;
  }

  private deviceStatus(request: number): void {
    if (request === 6) {
      this.responses.push(`\x1b[${this.cursorRow + 1};${this.cursorCol + 1}R`);
    } else if (request === 5) {
      this.responses.push('\x1b[0n');
    }
    if (this.responses.length > MAX_RESPONSE_QUEUE) {
      this.responses.shift();
    }
  }

  private sgr(): void {
    if (this.csiParams.length === 0) {
      this.attrFg = VT_FG_DEFAULT;
      this.attrBg = VT_FG_DEFAULT;
      this.attrFlags = 0;
      return;
    }
    let i: number = 0;
    while (i < this.csiParams.length) {
      const p: number = this.csiParams[i];
      if (p === 0) {
        this.attrFg = VT_FG_DEFAULT;
        this.attrBg = VT_FG_DEFAULT;
        this.attrFlags = 0;
      } else if (p === 1) {
        this.attrFlags |= VT_BOLD;
      } else if (p === 2) {
        this.attrFlags |= VT_DIM;
      } else if (p === 3) {
        this.attrFlags |= VT_ITALIC;
      } else if (p === 4) {
        this.attrFlags |= VT_UNDERLINE;
      } else if (p === 7) {
        this.attrFlags |= VT_INVERSE;
      } else if (p === 9) {
        this.attrFlags |= VT_STRIKE;
      } else if (p === 21 || p === 22) {
        this.attrFlags &= ~(VT_BOLD | VT_DIM);
      } else if (p === 23) {
        this.attrFlags &= ~VT_ITALIC;
      } else if (p === 24) {
        this.attrFlags &= ~VT_UNDERLINE;
      } else if (p === 27) {
        this.attrFlags &= ~VT_INVERSE;
      } else if (p === 29) {
        this.attrFlags &= ~VT_STRIKE;
      } else if (p >= 30 && p <= 37) {
        this.attrFg = p - 30;
      } else if (p === 39) {
        this.attrFg = VT_FG_DEFAULT;
      } else if (p >= 40 && p <= 47) {
        this.attrBg = p - 40;
      } else if (p === 49) {
        this.attrBg = VT_FG_DEFAULT;
      } else if (p >= 90 && p <= 97) {
        this.attrFg = p - 90 + 8;
      } else if (p >= 100 && p <= 107) {
        this.attrBg = p - 100 + 8;
      } else if (p === 38 || p === 48) {
        const isFg: boolean = p === 38;
        if (i + 1 < this.csiParams.length && this.csiParams[i + 1] === 5 &&
            i + 2 < this.csiParams.length) {
          const idx: number = this.csiParams[i + 2];
          if (isFg) {
            this.attrFg = idx >= 0 && idx <= 255 ? idx : VT_FG_DEFAULT;
          } else {
            this.attrBg = idx >= 0 && idx <= 255 ? idx : VT_FG_DEFAULT;
          }
          i += 2;
        } else if (i + 1 < this.csiParams.length && this.csiParams[i + 1] === 2 &&
                   i + 4 < this.csiParams.length) {
          const r: number = Math.min(this.csiParams[i + 2], 255);
          const g: number = Math.min(this.csiParams[i + 3], 255);
          const b: number = Math.min(this.csiParams[i + 4], 255);
          const color: number = VT_TRUE_COLOR | (r << 16) | (g << 8) | b;
          if (isFg) {
            this.attrFg = color;
          } else {
            this.attrBg = color;
          }
          i += 4;
        }
      }
      i++;
    }
  }

  // ------------------------------------------------------------ cursor & erase

  private moveRow(delta: number): void {
    this.cursorRow = Math.max(0, Math.min(this.rows - 1, this.cursorRow + delta));
    this.wrapPending = false;
  }

  private moveCol(delta: number): void {
    this.cursorCol = Math.max(0, Math.min(this.cols - 1, this.cursorCol + delta));
    this.wrapPending = false;
  }

  private carriageReturn(): void {
    this.cursorCol = 0;
    this.wrapPending = false;
  }

  private linefeed(): void {
    this.wrapPending = false;
    if (this.cursorRow === this.scrollBottom) {
      this.scrollUp(1);
    } else if (this.cursorRow < this.rows - 1) {
      this.cursorRow++;
    }
  }

  private reverseIndex(): void {
    if (this.cursorRow === this.scrollTop) {
      this.scrollDown(1);
    } else if (this.cursorRow > 0) {
      this.cursorRow--;
    }
  }

  private tabForward(count: number): void {
    for (let n = 0; n < count; n++) {
      let next: number = ((this.cursorCol / 8) + 1) * 8;
      if (next >= this.cols) {
        next = this.cols - 1;
      }
      this.cursorCol = next;
    }
    this.wrapPending = false;
  }

  private scrollUp(count: number): void {
    const top: number = this.scrollTop;
    const bottom: number = this.scrollBottom;
    for (let n = 0; n < count; n++) {
      const removed: Array<VtCell> | undefined = this.grid.splice(top, 1)[0];
      if (removed !== undefined) {
        if (!this.altActive && top === 0 && bottom === this.rows - 1) {
          this.scrollback.push(removed);
          while (this.scrollback.length > this.maxScrollback) {
            this.scrollback.shift();
          }
          this.viewportOffset = 0;
        }
      }
      this.grid.splice(bottom, 0, blankLine(this.cols, this.attrBg));
    }
    this.dirty = true;
  }

  private scrollDown(count: number): void {
    const top: number = this.scrollTop;
    const bottom: number = this.scrollBottom;
    for (let n = 0; n < count; n++) {
      this.grid.splice(bottom, 1);
      this.grid.splice(top, 0, blankLine(this.cols, this.attrBg));
    }
    this.dirty = true;
  }

  private eraseDisplay(mode: number): void {
    if (mode === 0) {
      this.eraseLine(0);
      for (let r = this.cursorRow + 1; r < this.rows; r++) {
        this.grid[r] = blankLine(this.cols, this.attrBg);
      }
    } else if (mode === 1) {
      for (let r = 0; r < this.cursorRow; r++) {
        this.grid[r] = blankLine(this.cols, this.attrBg);
      }
      this.eraseLine(1);
    } else if (mode === 2) {
      for (let r = 0; r < this.rows; r++) {
        this.grid[r] = blankLine(this.cols, this.attrBg);
      }
    } else if (mode === 3) {
      this.scrollback = [];
      this.viewportOffset = 0;
    }
    this.wrapPending = false;
    this.dirty = true;
  }

  private eraseLine(mode: number): void {
    const line: Array<VtCell> = this.grid[this.cursorRow];
    let start: number = 0;
    let end: number = this.cols;
    if (mode === 0) {
      start = this.cursorCol;
    } else if (mode === 1) {
      end = this.cursorCol + 1;
    }
    for (let c = start; c < end && c < this.cols; c++) {
      line[c] = new VtCell(' ', this.attrFg, this.attrBg, this.attrFlags);
    }
    this.dirty = true;
  }

  private insertLines(count: number): void {
    if (this.cursorRow < this.scrollTop || this.cursorRow > this.scrollBottom) {
      return;
    }
    for (let n = 0; n < count; n++) {
      this.grid.splice(this.scrollBottom, 1);
      this.grid.splice(this.cursorRow, 0, blankLine(this.cols, this.attrBg));
    }
    this.dirty = true;
  }

  private deleteLines(count: number): void {
    if (this.cursorRow < this.scrollTop || this.cursorRow > this.scrollBottom) {
      return;
    }
    for (let n = 0; n < count; n++) {
      this.grid.splice(this.cursorRow, 1);
      this.grid.splice(this.scrollBottom, 0, blankLine(this.cols, this.attrBg));
    }
    this.dirty = true;
  }

  private insertChars(count: number): void {
    const line: Array<VtCell> = this.grid[this.cursorRow];
    for (let n = 0; n < count; n++) {
      line.splice(this.cursorCol, 0, new VtCell(' ', this.attrFg, this.attrBg, this.attrFlags));
      line.splice(this.cols, 1);
    }
    this.dirty = true;
  }

  private deleteChars(count: number): void {
    const line: Array<VtCell> = this.grid[this.cursorRow];
    for (let n = 0; n < count; n++) {
      line.splice(this.cursorCol, 1);
      line.push(new VtCell(' ', this.attrFg, this.attrBg, this.attrFlags));
      if (line.length > this.cols) {
        line.splice(this.cols, line.length - this.cols);
      }
    }
    this.dirty = true;
  }

  private eraseChars(count: number): void {
    const line: Array<VtCell> = this.grid[this.cursorRow];
    for (let c = this.cursorCol; c < this.cols && c < this.cursorCol + count; c++) {
      line[c] = new VtCell(' ', this.attrFg, this.attrBg, this.attrFlags);
    }
    this.dirty = true;
  }

  private setScrollRegion(top: number, bottom: number): void {
    const t: number = Math.max(1, Math.min(top, this.rows)) - 1;
    const b: number = Math.max(1, Math.min(bottom, this.rows)) - 1;
    if (t < b) {
      this.scrollTop = t;
      this.scrollBottom = b;
      this.cursorRow = t;
      this.cursorCol = 0;
    }
    this.wrapPending = false;
  }

  private saveCursor(): void {
    this.savedRow = this.cursorRow;
    this.savedCol = this.cursorCol;
    this.savedFg = this.attrFg;
    this.savedBg = this.attrBg;
    this.savedFlags = this.attrFlags;
  }

  private restoreCursor(): void {
    this.cursorRow = Math.min(this.savedRow, this.rows - 1);
    this.cursorCol = Math.min(this.savedCol, this.cols - 1);
    this.attrFg = this.savedFg;
    this.attrBg = this.savedBg;
    this.attrFlags = this.savedFlags;
    this.wrapPending = false;
  }

  // ------------------------------------------------------------------ resize

  resize(cols: number, rows: number): void {
    const nextCols: number = Math.max(2, cols);
    const nextRows: number = Math.max(2, rows);
    if (nextCols === this.cols && nextRows === this.rows) {
      return;
    }
    const next: Array<Array<VtCell>> = [];
    for (let r = 0; r < nextRows; r++) {
      if (r < this.grid.length) {
        next.push(copyLine(this.grid[r], nextCols));
      } else {
        next.push(blankLine(nextCols, VT_FG_DEFAULT));
      }
    }
    for (let i = 0; i < this.scrollback.length; i++) {
      this.scrollback[i] = copyLine(this.scrollback[i], nextCols);
    }
    this.grid = next;
    this.cols = nextCols;
    this.rows = nextRows;
    this.cursorRow = Math.min(this.cursorRow, nextRows - 1);
    this.cursorCol = Math.min(this.cursorCol, nextCols - 1);
    this.scrollTop = 0;
    this.scrollBottom = nextRows - 1;
    this.wrapPending = false;
    this.viewportOffset = 0;
    this.dirty = true;
  }

  // ----------------------------------------------------------------- reading

  /** Line for screen row `row` at `offset` lines above the live view. */
  lineAt(row: number, offset: number = 0): Array<VtCell> | null {
    if (row < 0 || row >= this.rows) {
      return null;
    }
    const index: number = this.scrollback.length - offset + row;
    if (index < 0) {
      return null;
    }
    if (index < this.scrollback.length) {
      return this.scrollback[index];
    }
    const gridIndex: number = index - this.scrollback.length;
    if (gridIndex < 0 || gridIndex >= this.grid.length) {
      return null;
    }
    return this.grid[gridIndex];
  }

  maxOffset(): number {
    return this.scrollback.length;
  }

  currentOffset(): number {
    return this.viewportOffset;
  }

  scrollBy(lines: number): void {
    this.viewportOffset = Math.max(0, Math.min(this.maxOffset(),
                                                 this.viewportOffset + lines));
  }

  scrollToBottom(): void {
    this.viewportOffset = 0;
  }

  cursor(): VtCursor {
    return new VtCursor(this.cursorRow, this.cursorCol, this.cursorVisible);
  }

  takeResponses(): string {
    if (this.responses.length === 0) {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < this.responses.length; i++) {
      out += this.responses[i];
    }
    this.responses = [];
    return out;
  }

  consumeBell(): boolean {
    const bell: boolean = this.bellPending;
    this.bellPending = false;
    return bell;
  }

  takeDirty(): boolean {
    const value: boolean = this.dirty;
    this.dirty = false;
    return value;
  }

  /** Plain-text dump of the live screen (used by "copy screen"). */
  dumpText(): string {
    let out: string = '';
    for (let r = 0; r < this.rows; r++) {
      const line: Array<VtCell> | null = this.lineAt(r, this.viewportOffset);
      if (line === null) {
        continue;
      }
      let text: string = '';
      for (let c = 0; c < line.length; c++) {
        if (line[c].ch.length > 0) {
          text += line[c].ch;
        }
      }
      out += text.replace(/\s+$/, '') + '\n';
    }
    return out;
  }
}
