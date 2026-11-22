/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * POSIX-style path helpers for the virtual filesystem. The local pane maps
 * '/' to the application sandbox root, so all paths are absolute and
 * confined by construction.
 */

export function normalizePath(path: string): string {
  const parts: Array<string> = path.split('/');
  const stack: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (part === '' || part === '.') {
      continue;
    }
    if (part === '..') {
      if (stack.length > 0) {
        stack.pop();
      }
      continue;
    }
    stack.push(part);
  }
  return '/' + stack.join('/');
}

export function resolvePath(cwd: string, input: string): string {
  let path: string = input;
  if (path === '' || path === '~') {
    return path === '~' ? '/' : cwd;
  }
  if (path.startsWith('~/')) {
    path = path.substring(1);
  }
  if (!path.startsWith('/')) {
    path = (cwd === '/' ? '' : cwd) + '/' + path;
  }
  return normalizePath(path);
}

export function joinPath(base: string, name: string): string {
  if (name.startsWith('/')) {
    return normalizePath(name);
  }
  if (base === '/') {
    return normalizePath('/' + name);
  }
  return normalizePath(base + '/' + name);
}

export function parentPath(path: string): string {
  const normalized: string = normalizePath(path);
  if (normalized === '/') {
    return '/';
  }
  const index: number = normalized.lastIndexOf('/');
  return index <= 0 ? '/' : normalized.substring(0, index);
}

export function baseName(path: string): string {
  const normalized: string = normalizePath(path);
  if (normalized === '/') {
    return '/';
  }
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

/** Breadcrumb segments; root is represented by an empty array. */
export function pathSegments(path: string): Array<string> {
  const normalized: string = normalizePath(path);
  if (normalized === '/') {
    return [];
  }
  return normalized.substring(1).split('/');
}

export function isRoot(path: string): boolean {
  return normalizePath(path) === '/';
}
