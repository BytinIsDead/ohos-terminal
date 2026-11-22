/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { LocalFs } from '../fs/LocalFs';
import { LocalSession } from '../session/LocalSession';
import { SshSessionAdapter } from '../session/SshSessionAdapter';
import { TerminalSession } from '../session/TerminalSession';
import { SshProfile, ProfileStore } from '../services/ProfileStore';
import { SecretStore, passwordAlias, passphraseAlias } from '../services/SecretStore';
import { Paths } from '../services/Paths';
import { TerminalView } from '../ui/TerminalView';
import { Logger } from '../common/Logger';
import { requestStorage } from '../common/Permissions';

const TAG: string = 'Index';

class SessionTab {
  id: string;
  label: string;
  session: TerminalSession;

  constructor(id: string, label: string, session: TerminalSession) {
    this.id = id;
    this.label = label;
    this.session = session;
  }
}

@Entry
@Component
struct Index {
  @State sessions: Array<SessionTab> = [];
  @State activeId: string = '';
  @State profiles: Array<SshProfile> = [];
  @State connectState: string = '';
  @State pendingKind: string = '';
  @State pendingFingerprint: string = '';
  @State pendingPinned: string = '';
  @State pendingHost: string = '';

  @State formName: string = '';
  @State formHost: string = '';
  @State formPort: string = '22';
  @State formUser: string = '';
  @State formAuth: string = 'password';
  @State formPassword: string = '';
  @State formPassphrase: string = '';
  @State formKey: string = '';
  @State formFingerprint: string = '';
  @State formRemoteDir: string = '';

  private localFs: LocalFs | null = null;
  private localId: number = 0;
  private editingId: string = '';
  private pendingAdapter: SshSessionAdapter | null = null;
  private pendingProfile: SshProfile | null = null;
  private pendingPassword: string = '';
  private pendingPassphrase: string = '';
  private tabsController: TabsController = new TabsController();

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const context: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('ohterm.context');
    if (context !== undefined) {
      try {
        await ProfileStore.init(context);
        this.profiles = await ProfileStore.load();
      } catch (err) {
        Logger.warn(TAG, `profile init failed: ${(err as Error).message}`);
      }
      await requestStorage(context);
    }
    this.localFs = new LocalFs(Paths.filesDir());
    this.addLocalSession();
  }

  private addLocalSession(): void {
    if (this.localFs === null) {
      return;
    }
    this.localId++;
    const session: LocalSession = new LocalSession(this.localFs);
    const tab: SessionTab = new SessionTab(`local-${this.localId}`, `Local ${this.localId}`, session);
    this.sessions = this.sessions.concat([tab]);
    this.activate(tab.id);
  }

  private activate(id: string): void {
    this.activeId = id;
  }

  private closeTab(id: string): void {
    let closed: SessionTab | null = null;
    const remaining: Array<SessionTab> = [];
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) {
        closed = this.sessions[i];
      } else {
        remaining.push(this.sessions[i]);
      }
    }
    if (closed !== null) {
      closed.session.close();
    }
    this.sessions = remaining;
    if (this.activeId === id) {
      this.activeId = remaining.length > 0 ? remaining[remaining.length - 1].id : '';
    }
  }

  private activeSession(): TerminalSession | null {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === this.activeId) {
        return this.sessions[i].session;
      }
    }
    return null;
  }

  private resetForm(): void {
    this.editingId = '';
    this.formName = '';
    this.formHost = '';
    this.formPort = '22';
    this.formUser = '';
    this.formAuth = 'password';
    this.formPassword = '';
    this.formPassphrase = '';
    this.formKey = '';
    this.formFingerprint = '';
    this.formRemoteDir = '';
  }

  private editProfile(profile: SshProfile): void {
    this.editingId = profile.id;
    this.formName = profile.name;
    this.formHost = profile.host;
    this.formPort = `${profile.port}`;
    this.formUser = profile.user;
    this.formAuth = profile.auth;
    this.formKey = profile.privateKey;
    this.formFingerprint = profile.fingerprint;
    this.formRemoteDir = profile.remoteDir;
    SecretStore.get(passwordAlias(profile.id)).then((secret: string): void => {
      this.formPassword = secret;
    });
    SecretStore.get(passphraseAlias(profile.id)).then((secret: string): void => {
      this.formPassphrase = secret;
    });
  }

  private async saveProfile(): Promise<void> {
    if (this.formHost.length === 0 || this.formUser.length === 0) {
      promptAction.showToast({ message: 'Host and user are required' });
      return;
    }
    const profile: SshProfile = new SshProfile();
    profile.id = this.editingId.length > 0 ? this.editingId : `p${Date.now()}`;
    profile.name = this.formName;
    profile.host = this.formHost;
    profile.port = parseInt(this.formPort, 10) || 22;
    profile.user = this.formUser;
    profile.auth = this.formAuth;
    profile.privateKey = this.formKey;
    profile.publicKey = '';
    profile.fingerprint = this.formFingerprint.trim();
    profile.remoteDir = this.formRemoteDir;
    const next: Array<SshProfile> = [];
    let replaced: boolean = false;
    for (let i = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].id === profile.id) {
        next.push(profile);
        replaced = true;
      } else {
        next.push(this.profiles[i]);
      }
    }
    if (!replaced) {
      next.push(profile);
    }
    this.profiles = next;
    await ProfileStore.save(next);
    await SecretStore.set(passwordAlias(profile.id), this.formPassword);
    await SecretStore.set(passphraseAlias(profile.id), this.formPassphrase);
    this.editingId = profile.id;
    promptAction.showToast({ message: `Saved ${profile.label()}` });
  }

  private async deleteProfile(profile: SshProfile): Promise<void> {
    const next: Array<SshProfile> = this.profiles.filter(
      (item: SshProfile): boolean => item.id !== profile.id);
    this.profiles = next;
    await ProfileStore.save(next);
    await SecretStore.remove(passwordAlias(profile.id));
    await SecretStore.remove(passphraseAlias(profile.id));
    if (this.editingId === profile.id) {
      this.resetForm();
    }
  }

  private importPrivateKey(): void {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(options).then((uris: Array<string>): void => {
      if (uris.length === 0 || this.localFs === null) {
        return;
      }
      const uri: string = uris[0];
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      try {
        name = decodeURIComponent(name);
      } catch (err) {
        // keep the raw name
      }
      try {
        this.localFs.mkdir('/keys');
      } catch (exists) {
        // directory already present
      }
      const destination: string = this.localFs.real(`/keys/${name}`);
      const source: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(source.fd, destination);
      } finally {
        fs.closeSync(source);
      }
      this.formKey = `/keys/${name}`;
      promptAction.showToast({ message: `Imported ${name}` });
    }).catch((err: Error): void => {
      promptAction.showToast({ message: `Import failed: ${err.message}` });
    });
  }

  private async connectProfile(profile: SshProfile): Promise<void> {
    if (this.connectState.length > 0 && this.pendingKind.length > 0) {
      return;
    }
    this.connectState = `Connecting to ${profile.host}:${profile.port}…`;
    const adapter: SshSessionAdapter = new SshSessionAdapter(profile);
    let fingerprint: string = '';
    try {
      fingerprint = await adapter.handshake();
    } catch (err) {
      this.connectState = `Connection failed: ${(err as Error).message}`;
      return;
    }
    const password: string = await SecretStore.get(passwordAlias(profile.id));
    const passphrase: string = await SecretStore.get(passphraseAlias(profile.id));
    if (profile.fingerprint.length === 0) {
      this.pendingAdapter = adapter;
      this.pendingProfile = profile;
      this.pendingPassword = password;
      this.pendingPassphrase = passphrase;
      this.pendingPinned = '';
      this.pendingFingerprint = fingerprint;
      this.pendingHost = `${profile.user}@${profile.host}:${profile.port}`;
      this.pendingKind = 'trust';
      return;
    }
    if (profile.fingerprint !== fingerprint) {
      this.pendingAdapter = adapter;
      this.pendingProfile = profile;
      this.pendingPassword = password;
      this.pendingPassphrase = passphrase;
      this.pendingPinned = profile.fingerprint;
      this.pendingFingerprint = fingerprint;
      this.pendingHost = `${profile.user}@${profile.host}:${profile.port}`;
      this.pendingKind = 'mismatch';
      return;
    }
    await this.login(adapter, profile, password, passphrase);
  }

  private async login(adapter: SshSessionAdapter, profile: SshProfile,
                      password: string, passphrase: string): Promise<void> {
    try {
      await adapter.login(password, passphrase);
    } catch (err) {
      adapter.close();
      this.connectState = `Login failed: ${(err as Error).message}`;
      return;
    }
    const tab: SessionTab = new SessionTab(`ssh-${profile.id}-${Date.now()}`,
      profile.label(), adapter);
    this.sessions = this.sessions.concat([tab]);
    this.activate(tab.id);
    this.connectState = `Connected to ${profile.host}`;
    this.tabsController.changeIndex(0);
  }

  private async confirmPending(): Promise<void> {
    const adapter: SshSessionAdapter | null = this.pendingAdapter;
    const profile: SshProfile | null = this.pendingProfile;
    if (adapter === null || profile === null) {
      return;
    }
    profile.fingerprint = this.pendingFingerprint;
    const next: Array<SshProfile> = [];
    for (let i = 0; i < this.profiles.length; i++) {
      next.push(this.profiles[i].id === profile.id ? profile : this.profiles[i]);
    }
    this.profiles = next;
    await ProfileStore.save(next);
    this.formFingerprint = profile.fingerprint;
    const password: string = this.pendingPassword;
    const passphrase: string = this.pendingPassphrase;
    this.pendingKind = '';
    this.pendingAdapter = null;
    this.pendingProfile = null;
    await this.login(adapter, profile, password, passphrase);
  }

  private cancelPending(): void {
    if (this.pendingAdapter !== null) {
      this.pendingAdapter.close();
    }
    this.pendingAdapter = null;
    this.pendingProfile = null;
    this.pendingKind = '';
    this.connectState = 'Connection cancelled';
  }

  @Builder
  sessionChip(tab: SessionTab) {
    Row({ space: 6 }) {
      Text(tab.label)
        .fontSize(11)
        .fontColor(this.activeId === tab.id ? '#ffffff' : '#aab3c5')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick((): void => {
          this.activate(tab.id);
        })
      Text('✕')
        .fontSize(10)
        .fontColor('#8a93a8')
        .onClick((): void => {
          this.closeTab(tab.id);
        })
    }
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor(this.activeId === tab.id ? '#33415c' : '#252c3d')
    .borderRadius(5)
  }

  @Builder
  formField(label: string, value: string, key: string) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(10)
        .fontColor('#7f8aa3')
      TextInput({ text: value })
        .height(34)
        .fontSize(12)
        .fontColor('#d7dce8')
        .backgroundColor('#252c3d')
        .borderRadius(5)
        .onChange((next: string): void => {
          if (key === 'name') {
            this.formName = next;
          } else if (key === 'host') {
            this.formHost = next;
          } else if (key === 'port') {
            this.formPort = next;
          } else if (key === 'user') {
            this.formUser = next;
          } else if (key === 'password') {
            this.formPassword = next;
          } else if (key === 'passphrase') {
            this.formPassphrase = next;
          } else if (key === 'key') {
            this.formKey = next;
          } else if (key === 'fingerprint') {
            this.formFingerprint = next;
          } else if (key === 'remote') {
            this.formRemoteDir = next;
          }
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  terminalPage() {
    Column({ space: 0 }) {
      Row({ space: 6 }) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.sessions, (tab: SessionTab) => {
              this.sessionChip(tab)
            }, (tab: SessionTab): string => tab.id)
          }
          .padding({ left: 8, right: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)

        Button('+ Local')
          .height(26)
          .fontSize(10)
          .backgroundColor('#2b3448')
          .fontColor('#d7dce8')
          .borderRadius(5)
          .onClick((): void => {
            this.addLocalSession();
          })
      }
      .width('100%')
      .padding({ top: 6, bottom: 4 })

      if (this.activeSession() !== null) {
        TerminalView({
          controller: this.activeSession(),
          sessionKey: this.activeId
        })
          .layoutWeight(1)
      } else {
        Column() {
          Text('No terminal session')
            .fontSize(13)
            .fontColor('#7f8aa3')
          Text('Open a Local tab or connect a host from the Hosts tab.')
            .fontSize(11)
            .fontColor('#5c6579')
            .margin({ top: 6 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  profileRow(profile: SshProfile) {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Text(profile.label())
          .fontSize(12)
          .fontColor('#d7dce8')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(profile.fingerprint.length > 0 ? 'pinned' : 'unverified')
          .fontSize(9)
          .fontColor(profile.fingerprint.length > 0 ? '#98c379' : '#e5c07b')
      }
      Text(`${profile.user}@${profile.host}:${profile.port}  ${profile.auth}`)
        .fontSize(10)
        .fontColor('#7f8aa3')
      Row({ space: 6 }) {
        Button('Connect')
          .height(26)
          .fontSize(10)
          .backgroundColor('#3d59a1')
          .fontColor('#ffffff')
          .borderRadius(5)
          .onClick((): void => {
            this.connectProfile(profile);
          })
        Button('Edit')
          .height(26)
          .fontSize(10)
          .backgroundColor('#2b3448')
          .fontColor('#d7dce8')
          .borderRadius(5)
          .onClick((): void => {
            this.editProfile(profile);
          })
        Button('Delete')
          .height(26)
          .fontSize(10)
          .backgroundColor('#3a2b2f')
          .fontColor('#e06c75')
          .borderRadius(5)
          .onClick((): void => {
            this.deleteProfile(profile);
          })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(8)
    .backgroundColor('#20263a')
    .borderRadius(6)
  }

  @Builder
  hostsPage() {
    Scroll() {
      Column({ space: 8 }) {
        Text('Hosts')
          .fontSize(14)
          .fontColor('#d7dce8')
          .width('100%')
        Text(this.connectState)
          .fontSize(10)
          .fontColor(this.connectState.startsWith('Login failed') ||
            this.connectState.startsWith('Connection failed') ? '#e06c75' : '#7f8aa3')
          .width('100%')

        if (this.pendingKind.length > 0) {
          Column({ space: 6 }) {
            Text(this.pendingKind === 'mismatch' ? 'HOST KEY MISMATCH' : 'Verify host key')
              .fontSize(12)
              .fontColor(this.pendingKind === 'mismatch' ? '#e06c75' : '#e5c07b')
            Text(this.pendingHost)
              .fontSize(10)
              .fontColor('#aab3c5')
            if (this.pendingKind === 'mismatch') {
              Text(`pinned:   ${this.pendingPinned}`)
                .fontSize(9)
                .fontColor('#8a93a8')
            }
            Text(`received: ${this.pendingFingerprint}`)
              .fontSize(9)
              .fontColor('#d7dce8')
            Text(this.pendingKind === 'mismatch'
              ? 'The server key changed. Only replace the pin if you expected this.'
              : 'First connection to this host. Compare the fingerprint with the server admin.')
              .fontSize(9)
              .fontColor('#8a93a8')
            Row({ space: 6 }) {
              Button(this.pendingKind === 'mismatch' ? 'Replace pin' : 'Trust and connect')
                .height(28)
                .fontSize(10)
                .backgroundColor('#3d59a1')
                .fontColor('#ffffff')
                .borderRadius(5)
                .onClick((): void => {
                  this.confirmPending();
                })
              Button('Cancel')
                .height(28)
                .fontSize(10)
                .backgroundColor('#2b3448')
                .fontColor('#d7dce8')
                .borderRadius(5)
                .onClick((): void => {
                  this.cancelPending();
                })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(8)
          .backgroundColor('#2a2436')
          .borderRadius(6)
        }

        ForEach(this.profiles, (profile: SshProfile) => {
          this.profileRow(profile)
        }, (profile: SshProfile): string => profile.id)

        Text(this.editingId.length > 0 ? 'Edit host' : 'Add host')
          .fontSize(13)
          .fontColor('#d7dce8')
          .width('100%')
          .margin({ top: 6 })

        this.formField('Name', this.formName, 'name')
        this.formField('Host', this.formHost, 'host')
        this.formField('Port', this.formPort, 'port')
        this.formField('User', this.formUser, 'user')
        Row({ space: 6 }) {
          Button('password auth')
            .height(26)
            .fontSize(10)
            .backgroundColor(this.formAuth === 'password' ? '#3d59a1' : '#2b3448')
            .fontColor('#ffffff')
            .borderRadius(5)
            .onClick((): void => {
              this.formAuth = 'password';
            })
          Button('key auth')
            .height(26)
            .fontSize(10)
            .backgroundColor(this.formAuth === 'key' ? '#3d59a1' : '#2b3448')
            .fontColor('#ffffff')
            .borderRadius(5)
            .onClick((): void => {
              this.formAuth = 'key';
            })
        }
        .width('100%')

        if (this.formAuth === 'password') {
          this.formField('Password (stored in Asset Store Kit)',
            this.formPassword, 'password')
        } else {
          this.formField('Private key path in sandbox', this.formKey, 'key')
          Row({ space: 6 }) {
            Button('Import key')
              .height(26)
              .fontSize(10)
              .backgroundColor('#2b3448')
              .fontColor('#d7dce8')
              .borderRadius(5)
              .onClick((): void => {
                this.importPrivateKey();
              })
            Button('Public key is optional')
              .height(26)
              .fontSize(9)
              .backgroundColor('#20263a')
              .fontColor('#7f8aa3')
              .borderRadius(5)
              .onClick((): void => {
              })
          }
          .width('100%')
          this.formField('Key passphrase (optional)', this.formPassphrase, 'passphrase')
        }
        this.formField('Pinned fingerprint (leave empty to trust on first use)',
          this.formFingerprint, 'fingerprint')
        this.formField('Initial remote directory (optional)', this.formRemoteDir, 'remote')

        Row({ space: 6 }) {
          Button('Save host')
            .height(30)
            .fontSize(11)
            .backgroundColor('#3d59a1')
            .fontColor('#ffffff')
            .borderRadius(6)
            .onClick((): void => {
              this.saveProfile();
            })
          Button('Clear')
            .height(30)
            .fontSize(11)
            .backgroundColor('#2b3448')
            .fontColor('#d7dce8')
            .borderRadius(6)
            .onClick((): void => {
              this.resetForm();
            })
        }
        .width('100%')

        Text('Secrets stay in the Asset Store Kit. Host keys are verified before authentication; pins live in Preferences.')
          .fontSize(9)
          .fontColor('#5c6579')
          .width('100%')
          .margin({ bottom: 24 })
      }
      .padding(10)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  aboutPage() {
    Scroll() {
      Column({ space: 8 }) {
        Text('OHOS Terminal')
          .fontSize(18)
          .fontColor('#d7dce8')
        Text(`Version ${Paths.VERSION}`)
          .fontSize(10)
          .fontColor('#7f8aa3')
        Text('A terminal for HarmonyOS with a local sandbox shell, SSH sessions on libssh2, and read/write mounts for the public Download and Documents folders.')
          .fontSize(11)
          .fontColor('#aab3c5')
        Divider().color('#2b3448')
        Text('Licensed under the Mozilla Public License 2.0, Exhibit B (SPDX: MPL-2.0-no-copyleft-exception). Each source file carries the Exhibit A notice. The full license text is in the repository LICENSE file and in resources/rawfile/licenses/.')
          .fontSize(10)
          .fontColor('#aab3c5')
        Text('Third-party components')
          .fontSize(12)
          .fontColor('#d7dce8')
        Text('libssh2 1.11.1 - BSD 3-Clause\nmbedTLS 3.6.2 - Apache License 2.0')
          .fontSize(10)
          .fontColor('#aab3c5')
        Text('Both libraries are linked statically into libterminal_core.so. Their license texts and notices ship in this HAP under resources/rawfile/licenses and are also in the repository NOTICE file.')
          .fontSize(10)
          .fontColor('#7f8aa3')
        Divider().color('#2b3448')
        Text('Security notes')
          .fontSize(12)
          .fontColor('#d7dce8')
        Text('Host keys are checked before any credential is sent. The first contact stores a SHA-256 fingerprint (trust on first use); later changes are reported as mismatches. Passwords and key passphrases are stored in the system Asset Store Kit, never in Preferences or logs. Storage access is requested at runtime and can be declined.')
          .fontSize(10)
          .fontColor('#aab3c5')
        Text('Limitations')
          .fontSize(12)
          .fontColor('#d7dce8')
        Text('The HarmonyOS soft keyboard does not deliver raw printable key events, so interactive full-screen programs are driven through the key bar and line input. The sandbox pane is confined to the app files directory.')
          .fontSize(10)
          .fontColor('#aab3c5')
        Text('No warranty. Provided under the MPL 2.0 on an "AS IS" basis.')
          .fontSize(9)
          .fontColor('#5c6579')
          .margin({ bottom: 24 })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      TabContent() {
        this.terminalPage()
      }
      .tabBar('Terminal')

      TabContent() {
        this.hostsPage()
      }
      .tabBar('Hosts')

      TabContent() {
        this.aboutPage()
      }
      .tabBar('About')
    }
    .barMode(BarMode.Fixed)
    .backgroundColor('#1b2030')
    .width('100%')
    .height('100%')
  }
}
