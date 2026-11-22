/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Host profiles. Non-secret fields (host, user, port, pinned fingerprint,
 * key paths) live in Preferences; passwords/passphrases live in the Asset
 * Store Kit keyed by profile id.
 */

import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { JsonObj, parseJson, asObj, asArray, getStr, getNum } from '../common/JsonReader';

export class SshProfile {
  id: string = '';
  name: string = '';
  host: string = '';
  port: number = 22;
  user: string = '';
  /** 'password' or 'key'. */
  auth: string = 'password';
  /** Sandbox path of the private key file. */
  privateKey: string = '';
  /** Optional sandbox path of the OpenSSH public key file. */
  publicKey: string = '';
  /** Pinned SHA-256 fingerprint; empty until first trust. */
  fingerprint: string = '';
  /** Initial remote directory; empty means the SFTP home. */
  remoteDir: string = '';

  static fromJson(obj: JsonObj): SshProfile {
    const profile: SshProfile = new SshProfile();
    profile.id = getStr(obj, 'id');
    profile.name = getStr(obj, 'name');
    profile.host = getStr(obj, 'host');
    profile.port = getNum(obj, 'port', 22);
    profile.user = getStr(obj, 'user');
    profile.auth = getStr(obj, 'auth', 'password');
    profile.privateKey = getStr(obj, 'privateKey');
    profile.publicKey = getStr(obj, 'publicKey');
    profile.fingerprint = getStr(obj, 'fingerprint');
    profile.remoteDir = getStr(obj, 'remoteDir');
    return profile;
  }

  label(): string {
    return this.name.length > 0 ? this.name : `${this.user}@${this.host}`;
  }
}

const PREF_NAME: string = 'ohterm.profiles';
const PREF_KEY: string = 'hosts';

export class ProfileStore {
  private static prefs: preferences.Preferences | null = null;

  static async init(context: common.UIAbilityContext): Promise<void> {
    ProfileStore.prefs = await preferences.getPreferences(context, { name: PREF_NAME });
  }

  static async load(): Promise<Array<SshProfile>> {
    const out: Array<SshProfile> = [];
    if (ProfileStore.prefs === null) {
      return out;
    }
    const raw: string = await ProfileStore.prefs.get(PREF_KEY, '') as string;
    if (raw.length === 0) {
      return out;
    }
    const parsed: Object | null = parseJson(raw) as Object | null;
    const items: Array<Object> | null = asArray(parsed);
    if (items === null) {
      return out;
    }
    for (let i = 0; i < items.length; i++) {
      const obj: JsonObj | null = asObj(items[i]);
      if (obj !== null) {
        out.push(SshProfile.fromJson(obj));
      }
    }
    return out;
  }

  static async save(profiles: Array<SshProfile>): Promise<void> {
    if (ProfileStore.prefs === null) {
      return;
    }
    await ProfileStore.prefs.put(PREF_KEY, JSON.stringify(profiles));
    await ProfileStore.prefs.flush();
  }
}
