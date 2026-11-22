/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * Runtime storage permissions. Both are normal-level user_grant permissions
 * that unlock the public Download and Documents directories; the shell maps
 * them at /download and /documents.
 */

import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { Permissions } from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import { Logger } from './Logger';

const TAG: string = 'Permissions';

export const STORAGE_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
];

export async function requestStorage(context: common.UIAbilityContext): Promise<number> {
  const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  try {
    const result = await manager.requestPermissionsFromUser(context, STORAGE_PERMISSIONS);
    let granted: number = 0;
    for (let i = 0; i < result.authResults.length; i++) {
      if (result.authResults[i] === 0) {
        granted++;
      }
    }
    Logger.info(TAG, `storage permissions granted: ${granted}/${STORAGE_PERMISSIONS.length}`);
    return granted;
  } catch (err) {
    Logger.warn(TAG, `permission request failed: ${(err as Error).message}`);
    return 0;
  }
}
