/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Canvas painter for a VtScreen: 16/256/24-bit colours, bold, underline,
 * strike, inverse and a caret. Kept free of ArkUI state so it can be reasoned
 * about (and later unit-tested against a mock context).
 */

import {
  VtScreen, VtCell, VtCursor, VT_FG_DEFAULT, VT_TRUE_COLOR,
  VT_BOLD, VT_UNDERLINE, VT_INVERSE, VT_DIM, VT_STRIKE
} from '../core/ansi/VtScreen';

export const TERM_BG: string = '#1b2030';
export const TERM_FG: string = '#d7dce8';
export const TERM_CURSOR: string = '#7aa2f7';

const BASE_PALETTE: Array<string> = [
  '#3b4252', '#e06c75', '#98c379', '#e5c07b',
  '#61afef', '#c678dd', '#56b6c2', '#dcdfe4',
  '#5c6370', '#ff6b81', '#b8e994', '#ffd479',
  '#7aa2f7', '#d8a0f0', '#7fdbca', '#ffffff'
];

function hex(value: number): string {
  const text: string = value.toString(16);
  return text.length < 2 ? '0' + text : text;
}

function palette(n: number): string {
  if (n < 16) {
    return BASE_PALETTE[n < 0 ? 0 : n];
  }
  if (n >= 16 && n <= 231) {
    const c: number = n - 16;
    const r: number = Math.floor(c / 36);
    const g: number = Math.floor((c % 36) / 6);
    const b: number = c % 6;
    const step = (v: number): number => (v === 0 ? 0 : 55 + v * 40);
    return `rgb(${step(r)}, ${step(g)}, ${step(b)})`;
  }
  const grey: number = Math.max(0, Math.min(255, 8 + (n - 232) * 10));
  return `rgb(${grey}, ${grey}, ${grey})`;
}

export function colorCss(value: number, fallback: string): string {
  if (value === VT_FG_DEFAULT) {
    return fallback;
  }
  if ((value & VT_TRUE_COLOR) !== 0) {
    const rgb: number = value & 0xffffff;
    return `rgb(${(rgb >> 16) & 0xff}, ${(rgb >> 8) & 0xff}, ${rgb & 0xff})`;
  }
  return palette(value & 0xff);
}

export class TerminalMetrics {
  cellW: number;
  cellH: number;
  fontSize: number;
  cols: number;
  rows: number;

  constructor(cellW: number, cellH: number, fontSize: number, cols: number, rows: number) {
    this.cellW = cellW;
    this.cellH = cellH;
    this.fontSize = fontSize;
    this.cols = cols;
    this.rows = rows;
  }
}

export class TerminalPainter {
  /** Draws the visible viewport; returns the metrics used. */
  paint(ctx: CanvasRenderingContext2D, screen: VtScreen, width: number,
        height: number, fontSize: number): TerminalMetrics {
    const normalFont: string = `${fontSize}px monospace`;
    ctx.font = normalFont;
    const measured: number = ctx.measureText('M').width;
    const cellW: number = Math.max(4, Math.floor(measured * 100) / 100);
    const cellH: number = Math.round(fontSize * 1.35);
    const cols: number = Math.max(20, Math.floor(width / cellW));
    const rows: number = Math.max(4, Math.floor(height / cellH));
    const metrics: TerminalMetrics = new TerminalMetrics(cellW, cellH, fontSize, cols, rows);

    ctx.fillStyle = TERM_BG;
    ctx.fillRect(0, 0, width, height);
    ctx.textBaseline = 'top';

    const offset: number = screen.currentOffset();
    for (let row = 0; row < rows && row < screen.rows; row++) {
      const line: Array<VtCell> | null = screen.lineAt(row, offset);
      if (line === null) {
        break;
      }
      const y: number = row * cellH;
      for (let col = 0; col < cols && col < line.length; col++) {
        const cell: VtCell = line[col];
        if (cell.ch.length === 0) {
          continue;
        }
        const inverse: boolean = (cell.flags & VT_INVERSE) !== 0;
        let fg: string = colorCss(cell.fg, TERM_FG);
        let bg: string = colorCss(cell.bg, TERM_BG);
        if (inverse) {
          const swap: string = fg;
          fg = bg;
          bg = swap;
        }
        const x: number = col * cellW;
        if (bg !== TERM_BG) {
          ctx.fillStyle = bg;
          ctx.fillRect(x, y, cellW, cellH);
        }
        let font: string = `${fontSize}px monospace`;
        if ((cell.flags & VT_BOLD) !== 0) {
          font = `bold ${fontSize}px monospace`;
        }
        ctx.font = font;
        ctx.fillStyle = (cell.flags & VT_DIM) !== 0 ? TERM_FG : fg;
        ctx.fillText(cell.ch, x, y);
        if ((cell.flags & VT_UNDERLINE) !== 0) {
          ctx.fillRect(x, y + cellH - 2, cellW, 1);
        }
        if ((cell.flags & VT_STRIKE) !== 0) {
          ctx.fillRect(x, y + Math.floor(cellH / 2), cellW, 1);
        }
      }
    }

    const cursor: VtCursor = screen.cursor();
    if (cursor.visible && offset === 0 && cursor.row < rows && cursor.col < cols) {
      ctx.strokeStyle = TERM_CURSOR;
      ctx.lineWidth = 1;
      ctx.strokeRect(cursor.col * cellW + 0.5, cursor.row * cellH + 0.5,
        Math.max(2, cellW - 1), Math.max(2, cellH - 1));
    }
    return metrics;
  }
}
