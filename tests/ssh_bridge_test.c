/*
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Host integration test for ssh_bridge.c. Builds against desktop libssh2 and
 * exercises the same code paths the HAP uses: handshake/fingerprint, public
 * key auth, exec + stderr + exit status, PTY shell read/write/resize, and
 * SFTP list/stat/readlink/upload/download/rename/mkdir/unlink.
 *
 * Usage: ssh_bridge_test <host> <port> <user> <private_key_path>
 */

#include "ssh_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int g_failures = 0;
static int g_checks = 0;

static void check(int ok, const char* what) {
  g_checks++;
  if (!ok) {
    g_failures++;
    fprintf(stderr, "FAIL: %s\n", what);
  } else {
    printf("ok: %s\n", what);
  }
}

static TsshSession* connect_session(const char* host, int port,
                                    const char* user, const char* key) {
  char err[512];
  err[0] = '\0';
  TsshSession* s = tssh_connect(host, port, 8000, err, sizeof(err));
  if (s == NULL) {
    fprintf(stderr, "connect failed: %s\n", err);
    return NULL;
  }
  char type[64];
  char fp[64];
  tssh_hostkey(s, type, sizeof(type), fp, sizeof(fp));
  printf("host key: %s SHA256:%s\n", type, fp);
  check(strlen(fp) > 20, "host key fingerprint present");
  check(strcmp(type, "ssh-ed25519") == 0, "host key type is ssh-ed25519");
  char pub[1024];
  snprintf(pub, sizeof(pub), "%s.pub", key);
  err[0] = '\0';
  if (tssh_auth_key(s, user, pub, key, NULL, err, sizeof(err)) != TSSH_OK) {
    fprintf(stderr, "auth failed: %s\n", err);
    tssh_close(s);
    return NULL;
  }
  return s;
}

static int read_pump(TsshSession* s, char* out, int cap, int idle_limit_ms,
                     const char* marker) {
  int used = 0;
  int idle = 0;
  int done = 0;
  while (idle < idle_limit_ms) {
    uint8_t out_buf[8192];
    uint8_t err_buf[8192];
    long n = tssh_read(s, out_buf, sizeof(out_buf));
    long e = tssh_read_stderr(s, err_buf, sizeof(err_buf));
    if (n > 0) {
      long take = n < cap - 1 - used ? n : cap - 1 - used;
      if (take > 0) {
        memcpy(out + used, out_buf, (size_t)take);
        used += (int)take;
        out[used] = '\0';
      }
      idle = 0;
    }
    if (e > 0) {
      long take = e < cap - 1 - used ? e : cap - 1 - used;
      if (take > 0) {
        memcpy(out + used, err_buf, (size_t)take);
        used += (int)take;
        out[used] = '\0';
      }
      idle = 0;
    }
    if (marker != NULL && strstr(out, marker) != NULL) {
      done = 1;
      break;
    }
    if (n == TSSH_ERR_CLOSED || tssh_eof(s)) {
      done = 1;
      break;
    }
    if (n < 0 && n != TSSH_ERR_AGAIN) {
      break;
    }
    tssh_wait_socket(s, 1, 50);
    idle += 50;
  }
  out[used < cap ? used : cap - 1] = '\0';
  return done;
}

static int test_exec(const char* host, int port, const char* user,
                     const char* key) {
  TsshSession* s = connect_session(host, port, user, key);
  if (s == NULL) {
    return -1;
  }
  char err[512];
  err[0] = '\0';
  check(tssh_start_exec(s, "echo EXEC_OK; pwd; echo ERR_LINE 1>&2", 80, 24,
                        err, sizeof(err)) == TSSH_OK,
        "exec channel started");
  char out[16384];
  out[0] = '\0';
  read_pump(s, out, sizeof(out), 8000, NULL);
  printf("exec output:\n%s\n", out);
  check(strstr(out, "EXEC_OK") != NULL, "exec stdout received");
  check(strstr(out, "ERR_LINE") != NULL, "exec stderr received");
  int status = tssh_exit_status(s);
  check(status == 0, "exec exit status 0");
  tssh_close(s);
  return 0;
}

static int test_pty(const char* host, int port, const char* user,
                    const char* key) {
  TsshSession* s = connect_session(host, port, user, key);
  if (s == NULL) {
    return -1;
  }
  char err[512];
  err[0] = '\0';
  check(tssh_start_shell(s, 100, 30, err, sizeof(err)) == TSSH_OK,
        "pty shell started");
  check(tssh_resize(s, 120, 40) == TSSH_OK, "pty resize");
  const char* cmd = "echo PTY_$((6*7))_OK; exit\n";
  long written = tssh_write(s, (const uint8_t*)cmd, (int)strlen(cmd));
  check(written == (long)strlen(cmd), "pty write accepted");
  char out[16384];
  out[0] = '\0';
  read_pump(s, out, sizeof(out), 8000, "PTY_42_OK");
  printf("pty output:\n%s\n", out);
  check(strstr(out, "PTY_42_OK") != NULL, "pty command output received");
  read_pump(s, out, sizeof(out), 4000, NULL);
  check(tssh_exit_status(s) == 0, "pty shell exit status 0");
  tssh_close(s);
  return 0;
}

static int write_local(const char* path, const char* text) {
  FILE* f = fopen(path, "wb");
  if (f == NULL) {
    return -1;
  }
  size_t len = strlen(text);
  size_t n = fwrite(text, 1, len, f);
  fclose(f);
  return n == len ? 0 : -1;
}

static char* read_local(const char* path, int* out_len) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) {
    return NULL;
  }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* buf = (char*)malloc((size_t)len + 1);
  size_t n = fread(buf, 1, (size_t)len, f);
  buf[n] = '\0';
  fclose(f);
  if (out_len != NULL) {
    *out_len = (int)n;
  }
  return buf;
}

static int test_sftp(const char* host, int port, const char* user,
                     const char* key) {
  TsshSession* s = connect_session(host, port, user, key);
  if (s == NULL) {
    return -1;
  }
  char err[512];
  err[0] = '\0';
  check(tssh_sftp_init(s, err, sizeof(err)) == TSSH_OK, "sftp initialised");

  int pid = (int)getpid();
  char remote[512];
  char remote2[512];
  char local[512];
  char local2[512];
  snprintf(remote, sizeof(remote), "/tmp/ohterm-sftp-%d.bin", pid);
  snprintf(remote2, sizeof(remote2), "/tmp/ohterm-sftp-%d-renamed.bin", pid);
  snprintf(local, sizeof(local), "/tmp/ohterm-local-%d.bin", pid);
  snprintf(local2, sizeof(local2), "/tmp/ohterm-local-%d-back.bin", pid);
  const char* payload = "hello from the host integration test\nsecond line\n";
  check(write_local(local, payload) == 0, "local payload written");

  int64_t bytes = 0;
  err[0] = '\0';
  int rc = tssh_sftp_upload(s, local, remote, &bytes, err, sizeof(err));
  if (rc != TSSH_OK) {
    fprintf(stderr, "upload: %s\n", err);
  }
  check(rc == TSSH_OK && bytes == (int64_t)strlen(payload), "sftp upload");

  TsshEntry st;
  memset(&st, 0, sizeof(st));
  err[0] = '\0';
  check(tssh_sftp_stat(s, remote, 1, &st, err, sizeof(err)) == TSSH_OK,
        "sftp stat");
  check(!st.is_dir && st.size == (int64_t)strlen(payload),
        "stat size and type");
  tssh_entry_free(&st);

  TsshDir* dir = tssh_sftp_list(s, "/tmp", err, sizeof(err));
  check(dir != NULL && dir->count > 0, "sftp list /tmp");
  int found = 0;
  if (dir != NULL) {
    for (int i = 0; i < dir->count; i++) {
      if (strcmp(dir->entries[i].name, strrchr(remote, '/') + 1) == 0) {
        found = 1;
        check(dir->entries[i].size == (int64_t)strlen(payload),
              "listed entry size matches");
        check(!dir->entries[i].is_dir, "listed entry is a regular file");
        check(dir->entries[i].mtime > 100000, "listed entry has mtime");
      }
    }
    tssh_dir_free(dir);
  }
  check(found, "uploaded file appears in listing");

  check(tssh_sftp_rename(s, remote, remote2, err, sizeof(err)) == TSSH_OK,
        "sftp rename");
  check(tssh_sftp_unlink(s, remote, err, sizeof(err)) != TSSH_OK,
        "old name is gone after rename");

  bytes = 0;
  err[0] = '\0';
  rc = tssh_sftp_download(s, remote2, local2, &bytes, err, sizeof(err));
  if (rc != TSSH_OK) {
    fprintf(stderr, "download: %s\n", err);
  }
  check(rc == TSSH_OK && bytes == (int64_t)strlen(payload), "sftp download");
  int back_len = 0;
  char* back = read_local(local2, &back_len);
  check(back != NULL && back_len == (int)strlen(payload) &&
            memcmp(back, payload, (size_t)back_len) == 0,
        "downloaded bytes match");
  free(back);

  char rdir[512];
  snprintf(rdir, sizeof(rdir), "/tmp/ohterm-dir-%d", pid);
  check(tssh_sftp_mkdir(s, rdir, 0755, err, sizeof(err)) == TSSH_OK,
        "sftp mkdir");
  check(tssh_sftp_rmdir(s, rdir, err, sizeof(err)) == TSSH_OK,
        "sftp rmdir");
  check(tssh_sftp_unlink(s, remote2, err, sizeof(err)) == TSSH_OK,
        "sftp unlink");
  unlink(local);
  unlink(local2);
  tssh_close(s);
  return 0;
}

static int test_symlink(const char* host, int port, const char* user,
                        const char* key) {
  TsshSession* s = connect_session(host, port, user, key);
  if (s == NULL) {
    return -1;
  }
  char err[512];
  int pid = (int)getpid();
  char cmd[512];
  snprintf(cmd, sizeof(cmd), "ln -sfn /etc/hostname /tmp/ohterm-link-%d", pid);
  err[0] = '\0';
  if (tssh_start_exec(s, cmd, 80, 24, err, sizeof(err)) != TSSH_OK) {
    tssh_close(s);
    return -1;
  }
  char out[256];
  read_pump(s, out, sizeof(out), 4000, NULL);
  tssh_close(s);

  char target[512];
  snprintf(target, sizeof(target), "/tmp/ohterm-link-%d", pid);
  TsshSession* b = connect_session(host, port, user, key);
  if (b == NULL) {
    return -1;
  }
  err[0] = '\0';
  check(tssh_sftp_init(b, err, sizeof(err)) == TSSH_OK, "sftp for symlink");
  TsshEntry e;
  memset(&e, 0, sizeof(e));
  err[0] = '\0';
  check(tssh_sftp_stat(b, target, 0, &e, err, sizeof(err)) == TSSH_OK &&
            e.is_link,
        "lstat reports symlink");
  check(e.target != NULL && strcmp(e.target, "/etc/hostname") == 0,
        "readlink target matches");
  tssh_entry_free(&e);
  TsshEntry f;
  memset(&f, 0, sizeof(f));
  err[0] = '\0';
  check(tssh_sftp_stat(b, target, 1, &f, err, sizeof(err)) == TSSH_OK &&
            !f.is_link,
        "stat follows symlink");
  tssh_entry_free(&f);
  tssh_close(b);
  return 0;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: %s <host> <port> <user> <private_key>\n", argv[0]);
    return 2;
  }
  const char* host = argv[1];
  int port = atoi(argv[2]);
  const char* user = argv[3];
  const char* key = argv[4];

  if (test_exec(host, port, user, key) != 0) {
    return 1;
  }
  test_pty(host, port, user, key);
  test_sftp(host, port, user, key);
  test_symlink(host, port, user, key);

  printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
