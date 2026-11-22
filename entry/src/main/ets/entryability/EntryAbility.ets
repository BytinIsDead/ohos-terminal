/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { Logger } from '../common/Logger';
import { Paths } from '../services/Paths';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    AppStorage.setOrCreate<string>(Paths.FILES_DIR, this.context.filesDir);
    AppStorage.setOrCreate<string>(Paths.CACHE_DIR, this.context.cacheDir);
    AppStorage.setOrCreate<common.UIAbilityContext>('ohterm.context', this.context);
    Logger.info(TAG, `filesDir ${this.context.filesDir}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code !== 0) {
        Logger.error(TAG, `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(TAG, 'content loaded');
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor('#1b2030');
    });
  }
}
