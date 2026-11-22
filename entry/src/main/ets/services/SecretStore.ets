/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SSH secrets (passwords, key passphrases) in the Asset Store Kit, which is
 * backed by the device keystore. Never written to Preferences or logs.
 */

import asset from '@ohos.security.asset';
import util from '@ohos.util';
import { Logger } from '../common/Logger';
import { Utf8Decoder } from '../core/ansi/Keys';

const TAG: string = 'SecretStore';

export function passwordAlias(profileId: string): string {
  return `ohterm.ssh.password.${profileId}`;
}

export function passphraseAlias(profileId: string): string {
  return `ohterm.ssh.passphrase.${profileId}`;
}

function encode(text: string): Uint8Array {
  return new util.TextEncoder().encode(text);
}

function decode(bytes: Uint8Array): string {
  const decoder: Utf8Decoder = new Utf8Decoder();
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += decoder.push(bytes[i]);
  }
  return out;
}

export class SecretStore {
  static async set(alias: string, value: string): Promise<void> {
    if (value.length === 0) {
      await SecretStore.remove(alias);
      return;
    }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, encode(alias));
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.SECRET, encode(value));
      try {
        await asset.update(query, attrs);
        return;
      } catch (notFound) {
        // fall through to add
      }
      const addition: asset.AssetMap = new Map();
      addition.set(asset.Tag.ALIAS, encode(alias));
      addition.set(asset.Tag.SECRET, encode(value));
      addition.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      await asset.add(addition);
    } catch (err) {
      Logger.warn(TAG, `set ${alias} failed: ${(err as Error).message}`);
    }
  }

  static async get(alias: string): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, encode(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secret: Uint8Array | boolean | number | undefined =
        results[0].get(asset.Tag.SECRET);
      if (secret === undefined || typeof secret !== 'object') {
        return '';
      }
      return decode(secret as Uint8Array);
    } catch (err) {
      return '';
    }
  }

  static async remove(alias: string): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, encode(alias));
      await asset.remove(query);
    } catch (err) {
      // absent alias is fine
    }
  }
}
