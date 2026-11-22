/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/** AppStorage keys shared between EntryAbility, pages and components. */
export class Paths {
  static readonly FILES_DIR: string = 'ohterm.filesDir';
  static readonly CACHE_DIR: string = 'ohterm.cacheDir';
  static readonly VERSION: string = '1.0.0';

  static filesDir(): string {
    const value: string | undefined = AppStorage.get<string>(Paths.FILES_DIR);
    return value === undefined ? '' : value;
  }

  static cacheDir(): string {
    const value: string | undefined = AppStorage.get<string>(Paths.CACHE_DIR);
    return value === undefined ? '' : value;
  }
}
