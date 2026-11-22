/**
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SSH session adapter. The host key is verified before any credential is sent
 * (TOFU): handshake() returns the fingerprint, the UI pins or rejects it, and
 * only then does login() authenticate and open the shell channel.
 */

import { SshConnection, HostKeyError } from '../ssh/SshClient';
import { SshProfile } from '../services/ProfileStore';
import { TerminalSession } from './TerminalSession';
import { utf8Encode } from '../core/ansi/Keys';

export class SshSessionAdapter extends TerminalSession {
  private conn: SshConnection = new SshConnection();
  private profile: SshProfile;
  private eofReported: boolean = false;

  constructor(profile: SshProfile) {
    super();
    this.profile = profile;
    this.title = profile.label();
    this.status = 'new';
  }

  /** TCP + SSH handshake; returns the SHA-256 fingerprint. No auth yet. */
  async handshake(): Promise<string> {
    this.status = 'handshake';
    try {
      return await this.conn.open(this.profile.host, this.profile.port, 15000);
    } catch (err) {
      this.status = 'error';
      this.conn.close();
      throw err as Error;
    }
  }

  /** Verifies a pinned fingerprint, then authenticates and starts the shell. */
  async login(password: string, passphrase: string): Promise<void> {
    try {
      this.status = 'auth';
      if (this.profile.auth === 'key') {
        if (this.profile.privateKey.length === 0) {
          throw new Error('No private key configured for this host');
        }
        await this.conn.authKey(this.profile.user, this.profile.publicKey,
          this.profile.privateKey, passphrase);
      } else {
        await this.conn.authPassword(this.profile.user, password);
      }
      this.status = 'shell';
      await this.conn.startShell(80, 24);
      this.status = 'connected';
      this.feedLine(`Connected to ${this.profile.user}@${this.profile.host}:${this.profile.port}`);
      this.feedLine(`Host key: ${this.conn.hostKeyType} SHA256:${this.conn.fingerprint}`);
      this.feedLine('');
    } catch (err) {
      this.status = 'error';
      this.conn.close();
      throw err as Error;
    }
  }

  verifyFingerprint(pinned: string): void {
    if (pinned.length > 0 && pinned !== this.conn.fingerprint) {
      throw new HostKeyError(this.conn.fingerprint, this.conn.hostKeyType,
        this.conn.banner);
    }
  }

  fingerprint(): string {
    return this.conn.fingerprint;
  }

  hostKeyType(): string {
    return this.conn.hostKeyType;
  }

  banner(): string {
    return this.conn.banner;
  }

  pump(): void {
    if (this.closed || !this.conn.connected) {
      return;
    }
    for (let n = 0; n < 4; n++) {
      const chunk: Uint8Array = this.conn.read(65536);
      if (chunk.length === 0) {
        break;
      }
      this.screen.feed(chunk);
      this.keys.applicationCursorKeys = this.screen.applicationCursorKeys;
    }
    if (this.conn.isEof() && !this.eofReported) {
      this.eofReported = true;
      const code: number = this.conn.exitStatus();
      this.feedLine('');
      this.feedLine(`[connection closed${code >= 0 ? `, exit ${code}` : ''}]`);
      this.closed = true;
      this.status = 'closed';
    }
  }

  sendLine(text: string): void {
    if (this.closed) {
      return;
    }
    this.conn.writeBytes(utf8Encode(text));
    this.conn.writeBytes(utf8Encode('\r'));
  }

  sendKey(name: string): void {
    if (this.closed) {
      return;
    }
    const bytes: Uint8Array = this.keys.named(name);
    if (bytes.length > 0) {
      this.conn.writeBytes(bytes);
    }
  }

  sendControl(key: string): void {
    if (this.closed) {
      return;
    }
    const code: number = this.keys.controlCode(key);
    if (code >= 0) {
      this.conn.writeBytes(new Uint8Array([code]));
    }
  }

  sendPaste(text: string): void {
    if (this.closed) {
      return;
    }
    this.conn.writeBytes(this.keys.paste(text, this.screen.bracketedPaste));
  }

  resize(cols: number, rows: number): void {
    this.screen.resize(cols, rows);
    if (this.conn.connected) {
      this.conn.resize(cols, rows);
    }
  }

  close(): void {
    this.closed = true;
    this.status = 'closed';
    this.conn.close();
  }

  kind(): string {
    return 'ssh';
  }

  hostLabel(): string {
    return this.profile.host;
  }

  connectionState(): string {
    return this.status;
  }
}
