/*
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Thin, portable libssh2 facade used by the NAPI bridge and by the host
 * integration test. Everything here is plain C with no NAPI/OHOS types so the
 * exact same file can be built against the OHOS NDK inside the HAP and
 * against host libssh2 for end-to-end tests.
 *
 * The caller is expected to:
 *   1. tssh_connect()            (TCP + SSH handshake, no credentials sent)
 *   2. read the host-key fingerprint and compare/pin it
 *   3. tssh_auth_password() or tssh_auth_key()
 *   4. tssh_start_shell()  -> non-blocking terminal I/O, or
 *      tssh_sftp_init()    -> blocking SFTP calls (use a separate session)
 */

#ifndef OHTERM_SSH_BRIDGE_H
#define OHTERM_SSH_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TsshSession TsshSession;

typedef struct {
  int is_dir;
  int is_link;
  uint32_t mode;       /* POSIX mode incl. type bits, 0 when unknown */
  uint32_t uid;
  uint32_t gid;
  int64_t size;
  int64_t mtime;       /* seconds since epoch */
  int64_t atime;
  char* name;          /* UTF-8, owned by the entry */
  char* target;        /* symlink target or NULL */
  char* long_entry;    /* ls -l style line from readdir_ex or NULL */
} TsshEntry;

typedef struct {
  TsshEntry* entries;
  int count;
} TsshDir;

/* Error codes returned by the functions below. */
enum {
  TSSH_OK = 0,
  TSSH_ERR = -1,
  TSSH_ERR_AGAIN = -2,
  TSSH_ERR_CLOSED = -3,
  TSSH_ERR_CANCELLED = -4
};

/* TCP connect + SSH handshake. Credentials are NOT sent here. */
TsshSession* tssh_connect(const char* host, int port, int timeout_ms,
                          char* err, int errlen);
void tssh_close(TsshSession* s);

/* Host key identity of the negotiated server key. */
int tssh_hostkey(TsshSession* s, char* type, int type_cap,
                 char* sha256_b64, int b64_cap);

/* Server banner shown before authentication (may be empty). */
const char* tssh_banner(TsshSession* s);

/* Authentication. Return TSSH_OK or TSSH_ERR with err filled. */
int tssh_auth_password(TsshSession* s, const char* user, const char* password,
                       char* err, int errlen);
int tssh_auth_key(TsshSession* s, const char* user,
                  const char* public_key_path, const char* private_key_path,
                  const char* passphrase, char* err, int errlen);

/* Terminal channel. After start_shell/start_exec the session switches to
 * non-blocking I/O; read/write never wait longer than the timeout. */
int tssh_start_shell(TsshSession* s, int cols, int rows,
                     char* err, int errlen);
int tssh_start_exec(TsshSession* s, const char* command, int cols, int rows,
                    char* err, int errlen);
long tssh_read(TsshSession* s, uint8_t* buf, int cap);   /* >0 bytes, 0 AGAIN, <0 error */
long tssh_read_stderr(TsshSession* s, uint8_t* buf, int cap);
long tssh_write(TsshSession* s, const uint8_t* data, int len);
int tssh_resize(TsshSession* s, int cols, int rows);
int tssh_eof(TsshSession* s);
int tssh_exit_status(TsshSession* s);
int tssh_wait_socket(TsshSession* s, int for_read, int timeout_ms);

/* SFTP. Open a dedicated session for browsing long-lived operations. */
int tssh_sftp_init(TsshSession* s, char* err, int errlen);
void tssh_sftp_shutdown(TsshSession* s);
TsshDir* tssh_sftp_list(TsshSession* s, const char* path,
                        char* err, int errlen);
void tssh_dir_free(TsshDir* dir);
int tssh_sftp_stat(TsshSession* s, const char* path, int follow,
                   TsshEntry* out, char* err, int errlen);
void tssh_entry_free(TsshEntry* e);
int tssh_sftp_readlink(TsshSession* s, const char* path, char* out, int cap);
int tssh_sftp_realpath(TsshSession* s, const char* path, char* out, int cap);
int tssh_sftp_mkdir(TsshSession* s, const char* path, int mode,
                    char* err, int errlen);
int tssh_sftp_rmdir(TsshSession* s, const char* path, char* err, int errlen);
int tssh_sftp_unlink(TsshSession* s, const char* path, char* err, int errlen);
int tssh_sftp_rename(TsshSession* s, const char* from, const char* to,
                     char* err, int errlen);
int tssh_sftp_download(TsshSession* s, const char* remote, const char* local,
                       int64_t* out_bytes, char* err, int errlen);
int tssh_sftp_upload(TsshSession* s, const char* local, const char* remote,
                     int64_t* out_bytes, char* err, int errlen);

/* Cooperative cancellation for in-flight transfers (any session). */
void tssh_cancel_transfers(int cancel);

#ifdef __cplusplus
}
#endif

#endif
