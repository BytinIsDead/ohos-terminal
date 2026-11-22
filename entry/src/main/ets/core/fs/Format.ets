/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Formatting and sorting helpers shared by the file browser, the local shell
 * and the docs. Pure TypeScript.
 */

import { FileEntry } from './FileEntry';

export function humanSize(bytes: number): string {
  if (bytes < 0) {
    return '-';
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const units: Array<string> = ['KiB', 'MiB', 'GiB', 'TiB'];
  let value: number = bytes / 1024;
  let unit: number = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value = value / 1024;
    unit++;
  }
  const text: string = Number.isInteger(value) ? `${value}` : value.toFixed(1);
  return `${text} ${units[unit]}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** Local-time timestamp as `YYYY-MM-DD HH:MM`. */
export function formatDate(seconds: number): string {
  if (seconds <= 0) {
    return '—';
  }
  const date: Date = new Date(seconds * 1000);
  const year: number = date.getFullYear();
  return `${year}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
         `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/** Relative age ("3m ago") for compact list rows. */
export function relativeAge(seconds: number): string {
  if (seconds <= 0) {
    return '';
  }
  const delta: number = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
  if (delta < 60) {
    return 'now';
  }
  if (delta < 3600) {
    return `${Math.floor(delta / 60)}m`;
  }
  if (delta < 86400) {
    return `${Math.floor(delta / 3600)}h`;
  }
  if (delta < 86400 * 30) {
    return `${Math.floor(delta / 86400)}d`;
  }
  if (delta < 86400 * 365) {
    return `${Math.floor(delta / (86400 * 30))}mo`;
  }
  return `${Math.floor(delta / (86400 * 365))}y`;
}

/** Unix mode -> `drwxr-xr-x` (10 characters). */
export function modeString(mode: number): string {
  if (mode === 0) {
    return '----------';
  }
  let type: string = '-';
  const kind: number = mode & 0o170000;
  if (kind === 0o040000) {
    type = 'd';
  } else if (kind === 0o120000) {
    type = 'l';
  } else if (kind === 0o020000) {
    type = 'c';
  } else if (kind === 0o060000) {
    type = 'b';
  } else if (kind === 0o140000) {
    type = 's';
  } else if (kind === 0o010000) {
    type = 'p';
  }
  const bits: Array<number> = [
    0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001
  ];
  const letters: Array<string> = ['r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x'];
  let out: string = type;
  for (let i = 0; i < bits.length; i++) {
    out += (mode & bits[i]) !== 0 ? letters[i] : '-';
  }
  return out;
}

export function modeOctal(mode: number): string {
  return (mode & 0o7777).toString(8).padStart(4, '0');
}

/** Natural comparison so `file2` sorts before `file10`. */
export function naturalCompare(a: string, b: string): number {
  const left: string = a.toLowerCase();
  const right: string = b.toLowerCase();
  let i: number = 0;
  let j: number = 0;
  while (i < left.length && j < right.length) {
    const ca: string = left.charAt(i);
    const cb: string = right.charAt(j);
    const da: boolean = ca >= '0' && ca <= '9';
    const db: boolean = cb >= '0' && cb <= '9';
    if (da && db) {
      let na: number = 0;
      while (i < left.length && left.charAt(i) >= '0' && left.charAt(i) <= '9') {
        na = na * 10 + (left.charCodeAt(i) - 48);
        i++;
      }
      let nb: number = 0;
      while (j < right.length && right.charAt(j) >= '0' && right.charAt(j) <= '9') {
        nb = nb * 10 + (right.charCodeAt(j) - 48);
        j++;
      }
      if (na !== nb) {
        return na < nb ? -1 : 1;
      }
      continue;
    }
    if (ca !== cb) {
      return ca < cb ? -1 : 1;
    }
    i++;
    j++;
  }
  if (i < left.length) {
    return 1;
  }
  if (j < right.length) {
    return -1;
  }
  return 0;
}

/** Returns a new sorted array. key: name | size | time | type. */
export function sortEntries(entries: Array<FileEntry>, key: string,
                            ascending: boolean, dirsFirst: boolean): Array<FileEntry> {
  const copy: Array<FileEntry> = entries.slice();
  copy.sort((a: FileEntry, b: FileEntry): number => {
    if (dirsFirst && a.isDir !== b.isDir) {
      return a.isDir ? -1 : 1;
    }
    let result: number = 0;
    if (key === 'size') {
      result = a.size === b.size ? 0 : (a.size < b.size ? -1 : 1);
    } else if (key === 'time') {
      result = a.mtime === b.mtime ? 0 : (a.mtime < b.mtime ? -1 : 1);
    } else if (key === 'type') {
      result = a.isDir === b.isDir ? 0 : (a.isDir ? -1 : 1);
      if (result === 0) {
        result = naturalCompare(a.name, b.name);
      }
    } else {
      result = naturalCompare(a.name, b.name);
    }
    if (result === 0) {
      result = naturalCompare(a.name, b.name);
    }
    return ascending ? result : -result;
  });
  return copy;
}

export function filterEntries(entries: Array<FileEntry>, query: string):
    Array<FileEntry> {
  const needle: string = query.trim().toLowerCase();
  if (needle.length === 0) {
    return entries;
  }
  const out: Array<FileEntry> = [];
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].name.toLowerCase().indexOf(needle) >= 0) {
      out.push(entries[i]);
    }
  }
  return out;
}
