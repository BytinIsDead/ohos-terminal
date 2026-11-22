/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Keyboard/UTF-8 helpers shared by local and SSH sessions. Pure TypeScript.
 */

function fromCodes(codes: Array<number>): Uint8Array {
  const out: Uint8Array = new Uint8Array(codes.length);
  for (let i = 0; i < codes.length; i++) {
    out[i] = codes[i] & 0xff;
  }
  return out;
}

export function asciiBytes(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

export function utf8Encode(text: string): Uint8Array {
  const bytes: Array<number> = [];
  for (let i = 0; i < text.length; i++) {
    let cp: number = text.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) {
      bytes.push(cp);
    } else if (cp < 0x800) {
      bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
                 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    }
  }
  return fromCodes(bytes);
}

/** Streaming UTF-8 decoder (used for local-shell keystroke bytes). */
export class Utf8Decoder {
  private need: number = 0;
  private code: number = 0;

  push(byte: number): string {
    const b: number = byte & 0xff;
    if (this.need > 0) {
      if ((b & 0xc0) === 0x80) {
        this.code = (this.code << 6) | (b & 0x3f);
        this.need--;
        if (this.need === 0) {
          const cp: number = this.code;
          this.code = 0;
          return this.fromCodePoint(cp);
        }
        return '';
      }
      this.need = 0;
      this.code = 0;
      return '\ufffd';
    }
    if (b < 0x80) {
      return String.fromCharCode(b);
    }
    if (b >= 0xc2 && b <= 0xdf) {
      this.need = 1;
      this.code = b & 0x1f;
    } else if (b >= 0xe0 && b <= 0xef) {
      this.need = 2;
      this.code = b & 0x0f;
    } else if (b >= 0xf0 && b <= 0xf4) {
      this.need = 3;
      this.code = b & 0x07;
    } else {
      return '\ufffd';
    }
    return '';
  }

  private fromCodePoint(cp: number): string {
    if (cp <= 0xffff) {
      return String.fromCharCode(cp);
    }
    const v: number = cp - 0x10000;
    return String.fromCharCode(0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff));
  }
}

export class KeyEncoder {
  applicationCursorKeys: boolean = false;

  /** Named cursor/editing keys: up, down, left, right, home, end, ... */
  named(name: string): Uint8Array {
    const app: boolean = this.applicationCursorKeys;
    if (name === 'up') {
      return app ? fromCodes([0x1b, 0x4f, 0x41]) : fromCodes([0x1b, 0x5b, 0x41]);
    }
    if (name === 'down') {
      return app ? fromCodes([0x1b, 0x4f, 0x42]) : fromCodes([0x1b, 0x5b, 0x42]);
    }
    if (name === 'right') {
      return app ? fromCodes([0x1b, 0x4f, 0x43]) : fromCodes([0x1b, 0x5b, 0x43]);
    }
    if (name === 'left') {
      return app ? fromCodes([0x1b, 0x4f, 0x44]) : fromCodes([0x1b, 0x5b, 0x44]);
    }
    if (name === 'home') {
      return app ? fromCodes([0x1b, 0x4f, 0x48]) : fromCodes([0x1b, 0x5b, 0x48]);
    }
    if (name === 'end') {
      return app ? fromCodes([0x1b, 0x4f, 0x46]) : fromCodes([0x1b, 0x5b, 0x46]);
    }
    if (name === 'insert') {
      return fromCodes([0x1b, 0x5b, 0x32, 0x7e]);
    }
    if (name === 'delete') {
      return fromCodes([0x1b, 0x5b, 0x33, 0x7e]);
    }
    if (name === 'pageup') {
      return fromCodes([0x1b, 0x5b, 0x35, 0x7e]);
    }
    if (name === 'pagedown') {
      return fromCodes([0x1b, 0x5b, 0x36, 0x7e]);
    }
    if (name === 'backtab') {
      return fromCodes([0x1b, 0x5b, 0x5a]);
    }
    if (name === 'enter') {
      return fromCodes([0x0d]);
    }
    if (name === 'tab') {
      return fromCodes([0x09]);
    }
    if (name === 'backspace') {
      return fromCodes([0x7f]);
    }
    if (name === 'escape') {
      return fromCodes([0x1b]);
    }
    if (name === 'space') {
      return fromCodes([0x20]);
    }
    return new Uint8Array(0);
  }

  functionKey(index: number): Uint8Array {
    if (index === 1) {
      return fromCodes([0x1b, 0x4f, 0x50]);
    }
    if (index === 2) {
      return fromCodes([0x1b, 0x4f, 0x51]);
    }
    if (index === 3) {
      return fromCodes([0x1b, 0x4f, 0x52]);
    }
    if (index === 4) {
      return fromCodes([0x1b, 0x4f, 0x53]);
    }
    const code: number = index === 5 ? 15 : (index === 6 ? 17 : (index === 7 ? 18 :
      (index === 8 ? 19 : (index === 9 ? 20 : (index === 10 ? 21 :
      (index === 11 ? 23 : 24))))));
    const text: string = '\x1b[' + String(code) + '~';
    return asciiBytes(text);
  }

  /** Ctrl+<key> byte, or -1 when the combination has no C0 code. */
  controlCode(key: string): number {
    if (key.length !== 1) {
      return -1;
    }
    const ch: string = key.toLowerCase();
    const code: number = ch.charCodeAt(0);
    if (code >= 0x61 && code <= 0x7a) {
      return code - 0x60;
    }
    if (ch === '@') {
      return 0;
    }
    if (ch === '[') {
      return 0x1b;
    }
    if (ch === '\\') {
      return 0x1c;
    }
    if (ch === ']') {
      return 0x1d;
    }
    if (ch === '^') {
      return 0x1e;
    }
    if (ch === '_' || ch === '/') {
      return 0x1f;
    }
    if (ch === '?') {
      return 0x7f;
    }
    return -1;
  }

  paste(text: string, bracketed: boolean): Uint8Array {
    if (!bracketed) {
      return utf8Encode(text.replace(/\r\n/g, '\r').replace(/\n/g, '\r'));
    }
    const start: Uint8Array = asciiBytes('\x1b[200~');
    const body: Uint8Array = utf8Encode(text);
    const end: Uint8Array = asciiBytes('\x1b[201~');
    const out: Uint8Array = new Uint8Array(start.length + body.length + end.length);
    out.set(start, 0);
    out.set(body, start.length);
    out.set(end, start.length + body.length);
    return out;
  }
}
