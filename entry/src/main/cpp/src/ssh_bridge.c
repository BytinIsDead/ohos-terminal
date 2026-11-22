/*
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Portable libssh2 facade. No NAPI or OHOS types here: the host integration
 * test links this file against a desktop libssh2, the HAP links it against
 * libssh2+mbedTLS cross-compiled by the module's CMakeLists.
 */

#include "ssh_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <libssh2.h>
#include <libssh2_sftp.h>

#if defined(OHTERM_USE_MBEDTLS)
#include <mbedtls/sha256.h>
#else
#include <openssl/sha.h>
#endif

#define TSSH_IO_CHUNK (64 * 1024)

struct TsshSession {
  int sock;
  LIBSSH2_SESSION* session;
  LIBSSH2_CHANNEL* channel;
  LIBSSH2_SFTP* sftp;
  char hostkey_type[64];
  char hostkey_sha256[48];
  int nonblocking;
  int timeout_ms;
};

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static volatile int g_cancel = 0;

static void bridge_global_init(void) {
  libssh2_init(0);
}

static void set_err(char* err, int cap, const char* fmt, ...) {
  if (err == NULL || cap <= 0) {
    return;
  }
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(err, (size_t)cap, fmt, ap);
  va_end(ap);
}

static int session_error(TsshSession* s, char* err, int cap, const char* what) {
  if (s != NULL && s->session != NULL) {
    char* msg = NULL;
    int msg_len = 0;
    int code = libssh2_session_last_error(s->session, &msg, &msg_len, 0);
    set_err(err, cap, "%s (libssh2 %d: %s)", what, code,
            msg != NULL ? msg : "unknown error");
  } else {
    set_err(err, cap, "%s: %s", what, strerror(errno));
  }
  return TSSH_ERR;
}

static int sftp_error(TsshSession* s, char* err, int cap, const char* what) {
  unsigned long code = 0;
  if (s != NULL && s->sftp != NULL) {
    code = libssh2_sftp_last_error(s->sftp);
  }
  set_err(err, cap, "%s (sftp status %lu)", what, code);
  return TSSH_ERR;
}

static int tcp_connect(const char* host, int port, int timeout_ms,
                       char* err, int errlen) {
  struct addrinfo hints;
  struct addrinfo* res = NULL;
  char service[16];
  snprintf(service, sizeof(service), "%d", port);
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int gai = getaddrinfo(host, service, &hints, &res);
  if (gai != 0) {
    set_err(err, errlen, "cannot resolve %s: %s", host, gai_strerror(gai));
    return -1;
  }
  int fd = -1;
  int saved = 0;
  for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) {
      saved = errno;
      continue;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, ai->ai_addr, (socklen_t)ai->ai_addrlen);
    if (rc != 0 && errno == EINPROGRESS) {
      fd_set wfds;
      struct timeval tv;
      FD_ZERO(&wfds);
      FD_SET(fd, &wfds);
      tv.tv_sec = timeout_ms / 1000;
      tv.tv_usec = (timeout_ms % 1000) * 1000;
      rc = select(fd + 1, NULL, &wfds, NULL, &tv);
      if (rc > 0) {
        int so_error = 0;
        socklen_t slen = sizeof(so_error);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &slen);
        if (so_error == 0) {
          rc = 0;
        } else {
          errno = so_error;
          rc = -1;
        }
      } else {
        if (rc == 0) {
          errno = ETIMEDOUT;
        }
        rc = -1;
      }
    }
    if (rc == 0) {
      fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
      struct timeval tv;
      tv.tv_sec = timeout_ms / 1000;
      tv.tv_usec = (timeout_ms % 1000) * 1000;
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
      break;
    }
    saved = errno;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) {
    set_err(err, errlen, "connect to %s:%d failed: %s", host, port,
            strerror(saved != 0 ? saved : errno));
    return -1;
  }
  return fd;
}

static int sha256_b64(const void* data, size_t len, char* out, int cap) {
  unsigned char digest[32];
#if defined(OHTERM_USE_MBEDTLS)
  mbedtls_sha256((const unsigned char*)data, len, digest, 0);
#else
  SHA256((const unsigned char*)data, len, digest);
#endif
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (cap < 44) {
    return -1;
  }
  int pos = 0;
  size_t i = 0;
  for (; i + 2 < sizeof(digest); i += 3) {
    unsigned v = ((unsigned)digest[i] << 16) | ((unsigned)digest[i + 1] << 8) |
                 digest[i + 2];
    out[pos++] = alphabet[(v >> 18) & 63];
    out[pos++] = alphabet[(v >> 12) & 63];
    out[pos++] = alphabet[(v >> 6) & 63];
    out[pos++] = alphabet[v & 63];
  }
  if (i < sizeof(digest)) {
    unsigned v = (unsigned)digest[i] << 16;
    int remain = (int)(sizeof(digest) - i);
    if (remain == 2) {
      v |= (unsigned)digest[i + 1] << 8;
      out[pos++] = alphabet[(v >> 18) & 63];
      out[pos++] = alphabet[(v >> 12) & 63];
      out[pos++] = alphabet[(v >> 6) & 63];
    } else {
      out[pos++] = alphabet[(v >> 18) & 63];
      out[pos++] = alphabet[(v >> 12) & 63];
    }
  }
  out[pos] = '\0';
  return 0;
}

static const char* hostkey_type_name(int type) {
  switch (type) {
    case LIBSSH2_HOSTKEY_TYPE_RSA:
      return "ssh-rsa";
    case LIBSSH2_HOSTKEY_TYPE_DSS:
      return "ssh-dss";
#ifdef LIBSSH2_HOSTKEY_TYPE_ECDSA_256
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256:
      return "ecdsa-sha2-nistp256";
#endif
#ifdef LIBSSH2_HOSTKEY_TYPE_ECDSA_384
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384:
      return "ecdsa-sha2-nistp384";
#endif
#ifdef LIBSSH2_HOSTKEY_TYPE_ECDSA_521
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521:
      return "ecdsa-sha2-nistp521";
#endif
#ifdef LIBSSH2_HOSTKEY_TYPE_ED25519
    case LIBSSH2_HOSTKEY_TYPE_ED25519:
      return "ssh-ed25519";
#endif
    default:
      return "unknown";
  }
}

TsshSession* tssh_connect(const char* host, int port, int timeout_ms,
                          char* err, int errlen) {
  if (host == NULL || port <= 0 || port > 65535) {
    set_err(err, errlen, "invalid host or port");
    return NULL;
  }
  if (timeout_ms <= 0) {
    timeout_ms = 15000;
  }
  pthread_once(&g_init_once, bridge_global_init);
  int fd = tcp_connect(host, port, timeout_ms, err, errlen);
  if (fd < 0) {
    return NULL;
  }
  TsshSession* s = (TsshSession*)calloc(1, sizeof(TsshSession));
  if (s == NULL) {
    close(fd);
    set_err(err, errlen, "out of memory");
    return NULL;
  }
  s->sock = fd;
  s->timeout_ms = timeout_ms;
  s->session = libssh2_session_init();
  if (s->session == NULL) {
    set_err(err, errlen, "libssh2_session_init failed");
    tssh_close(s);
    return NULL;
  }
  libssh2_session_set_blocking(s->session, 1);
  libssh2_session_set_timeout(s->session, (long)timeout_ms);
  if (libssh2_session_handshake(s->session, fd) != 0) {
    session_error(s, err, errlen, "SSH handshake failed");
    tssh_close(s);
    return NULL;
  }
  size_t key_len = 0;
  int key_type = 0;
  const char* key = libssh2_session_hostkey(s->session, &key_len, &key_type);
  if (key == NULL || key_len == 0) {
    set_err(err, errlen, "server did not present a host key");
    tssh_close(s);
    return NULL;
  }
  snprintf(s->hostkey_type, sizeof(s->hostkey_type), "%s",
           hostkey_type_name(key_type));
  if (sha256_b64(key, key_len, s->hostkey_sha256,
                 (int)sizeof(s->hostkey_sha256)) != 0) {
    set_err(err, errlen, "cannot hash host key");
    tssh_close(s);
    return NULL;
  }
  return s;
}

void tssh_close(TsshSession* s) {
  if (s == NULL) {
    return;
  }
  g_cancel = 1;
  if (s->sftp != NULL) {
    libssh2_sftp_shutdown(s->sftp);
    s->sftp = NULL;
  }
  if (s->channel != NULL) {
    libssh2_channel_send_eof(s->channel);
    libssh2_channel_close(s->channel);
    libssh2_channel_free(s->channel);
    s->channel = NULL;
  }
  if (s->session != NULL) {
    libssh2_session_set_blocking(s->session, 1);
    libssh2_session_set_timeout(s->session, 1000);
    libssh2_session_disconnect(s->session, "client disconnect");
    libssh2_session_free(s->session);
    s->session = NULL;
  }
  if (s->sock >= 0) {
    close(s->sock);
    s->sock = -1;
  }
  free(s);
}

int tssh_hostkey(TsshSession* s, char* type, int type_cap,
                 char* sha256, int b64_cap) {
  if (s == NULL) {
    return TSSH_ERR;
  }
  if (type != NULL && type_cap > 0) {
    snprintf(type, (size_t)type_cap, "%s", s->hostkey_type);
  }
  if (sha256 != NULL && b64_cap > 0) {
    snprintf(sha256, (size_t)b64_cap, "%s", s->hostkey_sha256);
  }
  return TSSH_OK;
}

const char* tssh_banner(TsshSession* s) {
  if (s == NULL || s->session == NULL) {
    return "";
  }
  const char* banner = libssh2_session_banner_get(s->session);
  return banner != NULL ? banner : "";
}

int tssh_auth_password(TsshSession* s, const char* user, const char* password,
                       char* err, int errlen) {
  if (s == NULL || s->session == NULL || user == NULL || password == NULL) {
    set_err(err, errlen, "invalid authentication arguments");
    return TSSH_ERR;
  }
  int rc = libssh2_userauth_password(s->session, user, password);
  if (rc != 0) {
    return session_error(s, err, errlen, "password authentication rejected");
  }
  return TSSH_OK;
}

int tssh_auth_key(TsshSession* s, const char* user,
                  const char* public_key_path, const char* private_key_path,
                  const char* passphrase, char* err, int errlen) {
  if (s == NULL || s->session == NULL || user == NULL ||
      private_key_path == NULL) {
    set_err(err, errlen, "invalid key authentication arguments");
    return TSSH_ERR;
  }
  int rc = libssh2_userauth_publickey_fromfile_ex(
      s->session, user, (unsigned int)strlen(user),
      (public_key_path != NULL && public_key_path[0] != '\0')
          ? public_key_path
          : NULL,
      private_key_path, passphrase);
  if (rc != 0) {
    return session_error(s, err, errlen, "public key authentication failed");
  }
  return TSSH_OK;
}

static int open_channel(TsshSession* s, char* err, int errlen) {
  if (s->channel != NULL) {
    libssh2_channel_free(s->channel);
    s->channel = NULL;
  }
  s->channel = libssh2_channel_open_session(s->session);
  if (s->channel == NULL) {
    return session_error(s, err, errlen, "cannot open SSH channel");
  }
  return TSSH_OK;
}

static int request_pty(TsshSession* s, int cols, int rows, char* err,
                       int errlen) {
  if (cols <= 0) {
    cols = 80;
  }
  if (rows <= 0) {
    rows = 24;
  }
  const char* term = "xterm-256color";
  int rc = libssh2_channel_request_pty_ex(s->channel, term,
                                          (unsigned int)strlen(term), NULL, 0,
                                          cols, rows, 0, 0);
  if (rc != 0) {
    return session_error(s, err, errlen, "PTY request rejected");
  }
  return TSSH_OK;
}

int tssh_start_shell(TsshSession* s, int cols, int rows,
                     char* err, int errlen) {
  if (s == NULL || s->session == NULL) {
    set_err(err, errlen, "not connected");
    return TSSH_ERR;
  }
  if (s->channel != NULL) {
    set_err(err, errlen, "channel already open");
    return TSSH_ERR;
  }
  if (open_channel(s, err, errlen) != TSSH_OK) {
    return TSSH_ERR;
  }
  if (request_pty(s, cols, rows, err, errlen) != TSSH_OK) {
    return TSSH_ERR;
  }
  if (libssh2_channel_shell(s->channel) != 0) {
    return session_error(s, err, errlen, "shell request rejected");
  }
  s->nonblocking = 1;
  libssh2_session_set_blocking(s->session, 0);
  return TSSH_OK;
}

int tssh_start_exec(TsshSession* s, const char* command, int cols, int rows,
                    char* err, int errlen) {
  if (s == NULL || s->session == NULL || command == NULL) {
    set_err(err, errlen, "not connected");
    return TSSH_ERR;
  }
  if (s->channel != NULL) {
    set_err(err, errlen, "channel already open");
    return TSSH_ERR;
  }
  if (open_channel(s, err, errlen) != TSSH_OK) {
    return TSSH_ERR;
  }
  (void)cols;
  (void)rows;
  if (libssh2_channel_exec(s->channel, command) != 0) {
    return session_error(s, err, errlen, "exec request rejected");
  }
  s->nonblocking = 1;
  libssh2_session_set_blocking(s->session, 0);
  return TSSH_OK;
}

int tssh_wait_socket(TsshSession* s, int for_read, int timeout_ms) {
  if (s == NULL || s->sock < 0) {
    return -1;
  }
  fd_set fds;
  FD_ZERO(&fds);
  FD_SET(s->sock, &fds);
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  int rc = select(s->sock + 1, for_read ? &fds : NULL, for_read ? NULL : &fds,
                  NULL, &tv);
  return rc;
}

long tssh_read(TsshSession* s, uint8_t* buf, int cap) {
  if (s == NULL || s->channel == NULL || buf == NULL || cap <= 0) {
    return TSSH_ERR;
  }
  long n = libssh2_channel_read(s->channel, (char*)buf, (size_t)cap);
  if (n > 0) {
    return n;
  }
  if (n == LIBSSH2_ERROR_EAGAIN) {
    return TSSH_ERR_AGAIN;
  }
  if (n == 0) {
    return libssh2_channel_eof(s->channel) ? TSSH_ERR_CLOSED : 0;
  }
  return TSSH_ERR;
}

long tssh_read_stderr(TsshSession* s, uint8_t* buf, int cap) {
  if (s == NULL || s->channel == NULL || buf == NULL || cap <= 0) {
    return TSSH_ERR;
  }
  long n = libssh2_channel_read_stderr(s->channel, (char*)buf, (size_t)cap);
  if (n > 0) {
    return n;
  }
  if (n == LIBSSH2_ERROR_EAGAIN) {
    return TSSH_ERR_AGAIN;
  }
  return 0;
}

long tssh_write(TsshSession* s, const uint8_t* data, int len) {
  if (s == NULL || s->channel == NULL || data == NULL || len <= 0) {
    return TSSH_ERR;
  }
  int off = 0;
  int idle_ms = 0;
  while (off < len) {
    long n = libssh2_channel_write(s->channel, (const char*)data + off,
                                   (size_t)(len - off));
    if (n > 0) {
      off += (int)n;
      idle_ms = 0;
      continue;
    }
    if (n == LIBSSH2_ERROR_EAGAIN) {
      if (tssh_wait_socket(s, 0, 200) > 0) {
        continue;
      }
      idle_ms += 200;
      if (idle_ms >= 2000) {
        break;
      }
      continue;
    }
    return TSSH_ERR;
  }
  return off;
}

int tssh_resize(TsshSession* s, int cols, int rows) {
  if (s == NULL || s->channel == NULL || cols <= 0 || rows <= 0) {
    return TSSH_ERR;
  }
  for (int attempt = 0; attempt < 20; attempt++) {
    int rc = libssh2_channel_request_pty_size_ex(s->channel, cols, rows, 0, 0);
    if (rc == 0) {
      return TSSH_OK;
    }
    if (rc == LIBSSH2_ERROR_EAGAIN) {
      tssh_wait_socket(s, 1, 100);
      continue;
    }
    return TSSH_ERR;
  }
  return TSSH_ERR;
}

int tssh_eof(TsshSession* s) {
  if (s == NULL || s->channel == NULL) {
    return 1;
  }
  return libssh2_channel_eof(s->channel) ? 1 : 0;
}

int tssh_exit_status(TsshSession* s) {
  if (s == NULL || s->channel == NULL) {
    return -1;
  }
  int status = libssh2_channel_get_exit_status(s->channel);
  return status;
}

int tssh_sftp_init(TsshSession* s, char* err, int errlen) {
  if (s == NULL || s->session == NULL) {
    set_err(err, errlen, "not connected");
    return TSSH_ERR;
  }
  if (s->channel != NULL) {
    set_err(err, errlen, "this session already owns a terminal channel");
    return TSSH_ERR;
  }
  libssh2_session_set_blocking(s->session, 1);
  libssh2_session_set_timeout(s->session, (long)(s->timeout_ms > 0
                                                     ? s->timeout_ms
                                                     : 30000));
  s->sftp = libssh2_sftp_init(s->session);
  if (s->sftp == NULL) {
    return session_error(s, err, errlen, "SFTP subsystem unavailable");
  }
  s->nonblocking = 0;
  return TSSH_OK;
}

void tssh_sftp_shutdown(TsshSession* s) {
  if (s != NULL && s->sftp != NULL) {
    libssh2_sftp_shutdown(s->sftp);
    s->sftp = NULL;
  }
}

static char* dup_range(const char* s, size_t n) {
  char* out = (char*)malloc(n + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, s, n);
  out[n] = '\0';
  return out;
}

static char* join_path(const char* base, const char* name) {
  if (base == NULL || *base == '\0') {
    base = ".";
  }
  size_t base_len = strlen(base);
  size_t name_len = strlen(name);
  int slash = base[base_len - 1] != '/';
  char* out = (char*)malloc(base_len + (size_t)slash + name_len + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, base, base_len);
  size_t pos = base_len;
  if (slash) {
    out[pos++] = '/';
  }
  memcpy(out + pos, name, name_len);
  out[pos + name_len] = '\0';
  return out;
}

static void fill_entry(TsshEntry* e, const char* name, const char* long_entry,
                       const LIBSSH2_SFTP_ATTRIBUTES* attrs) {
  memset(e, 0, sizeof(*e));
  e->name = name != NULL ? dup_range(name, strlen(name)) : NULL;
  e->long_entry = long_entry != NULL && *long_entry != '\0'
                      ? dup_range(long_entry, strlen(long_entry))
                      : NULL;
  if (attrs == NULL) {
    return;
  }
  if (attrs->flags & LIBSSH2_SFTP_ATTR_SIZE) {
    e->size = (int64_t)attrs->filesize;
  }
  if (attrs->flags & LIBSSH2_SFTP_ATTR_UIDGID) {
    e->uid = attrs->uid;
    e->gid = attrs->gid;
  }
  if (attrs->flags & LIBSSH2_SFTP_ATTR_ACMODTIME) {
    e->atime = (int64_t)attrs->atime;
    e->mtime = (int64_t)attrs->mtime;
  }
  if (attrs->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) {
    e->mode = attrs->permissions;
    e->is_dir = S_ISDIR(attrs->permissions) ? 1 : 0;
    e->is_link = S_ISLNK(attrs->permissions) ? 1 : 0;
  }
}

void tssh_entry_free(TsshEntry* e) {
  if (e == NULL) {
    return;
  }
  free(e->name);
  free(e->target);
  free(e->long_entry);
  e->name = NULL;
  e->target = NULL;
  e->long_entry = NULL;
}

TsshDir* tssh_sftp_list(TsshSession* s, const char* path,
                        char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || path == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return NULL;
  }
  LIBSSH2_SFTP_HANDLE* handle = libssh2_sftp_opendir(s->sftp, path);
  if (handle == NULL) {
    sftp_error(s, err, errlen, "cannot open directory");
    return NULL;
  }
  TsshDir* dir = (TsshDir*)calloc(1, sizeof(TsshDir));
  int capacity = 0;
  char name[4096];
  char long_entry[4096];
  LIBSSH2_SFTP_ATTRIBUTES attrs;
  for (;;) {
    memset(&attrs, 0, sizeof(attrs));
    int rc = libssh2_sftp_readdir_ex(handle, name, sizeof(name), long_entry,
                                     sizeof(long_entry), &attrs);
    if (rc == 0) {
      break;
    }
    if (rc < 0) {
      libssh2_sftp_closedir(handle);
      tssh_dir_free(dir);
      sftp_error(s, err, errlen, "directory read failed");
      return NULL;
    }
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
      continue;
    }
    if (dir->count == capacity) {
      int next = capacity == 0 ? 32 : capacity * 2;
      TsshEntry* grown =
          (TsshEntry*)realloc(dir->entries, (size_t)next * sizeof(TsshEntry));
      if (grown == NULL) {
        libssh2_sftp_closedir(handle);
        tssh_dir_free(dir);
        set_err(err, errlen, "out of memory");
        return NULL;
      }
      dir->entries = grown;
      capacity = next;
    }
    TsshEntry* e = &dir->entries[dir->count];
    fill_entry(e, name, long_entry, &attrs);
    if (e->is_link) {
      char* full = join_path(path, name);
      if (full != NULL) {
        char target[4096];
        ssize_t target_len =
            libssh2_sftp_readlink(s->sftp, full, target, sizeof(target));
        if (target_len > 0 && (size_t)target_len < sizeof(target)) {
          e->target = dup_range(target, (size_t)target_len);
        }
        free(full);
      }
    }
    dir->count++;
  }
  libssh2_sftp_closedir(handle);
  return dir;
}

void tssh_dir_free(TsshDir* dir) {
  if (dir == NULL) {
    return;
  }
  for (int i = 0; i < dir->count; i++) {
    tssh_entry_free(&dir->entries[i]);
  }
  free(dir->entries);
  free(dir);
}

int tssh_sftp_stat(TsshSession* s, const char* path, int follow,
                   TsshEntry* out, char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || path == NULL || out == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  LIBSSH2_SFTP_ATTRIBUTES attrs;
  memset(&attrs, 0, sizeof(attrs));
  int rc = libssh2_sftp_stat_ex(s->sftp, path, (unsigned int)strlen(path),
                                follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT,
                                &attrs);
  if (rc != 0) {
    return sftp_error(s, err, errlen, "stat failed");
  }
  fill_entry(out, path, NULL, &attrs);
  if (out->is_link && !follow) {
    char target[4096];
    ssize_t n = libssh2_sftp_readlink(s->sftp, path, target, sizeof(target));
    if (n > 0 && (size_t)n < sizeof(target)) {
      out->target = dup_range(target, (size_t)n);
    }
  }
  return TSSH_OK;
}

int tssh_sftp_readlink(TsshSession* s, const char* path, char* out, int cap) {
  if (s == NULL || s->sftp == NULL || path == NULL || out == NULL || cap <= 0) {
    return TSSH_ERR;
  }
  ssize_t n = libssh2_sftp_readlink(s->sftp, path, out, (size_t)cap - 1);
  if (n < 0) {
    return TSSH_ERR;
  }
  out[n < cap ? n : cap - 1] = '\0';
  return TSSH_OK;
}

int tssh_sftp_realpath(TsshSession* s, const char* path, char* out, int cap) {
  if (s == NULL || s->sftp == NULL || path == NULL || out == NULL || cap <= 0) {
    return TSSH_ERR;
  }
  int n = libssh2_sftp_realpath(s->sftp, path, out, (size_t)cap - 1);
  if (n < 0) {
    return TSSH_ERR;
  }
  out[n < cap ? n : cap - 1] = '\0';
  return TSSH_OK;
}

int tssh_sftp_mkdir(TsshSession* s, const char* path, int mode,
                    char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || path == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  if (libssh2_sftp_mkdir(s->sftp, path, (long)(mode > 0 ? mode : 0755)) != 0) {
    return sftp_error(s, err, errlen, "mkdir failed");
  }
  return TSSH_OK;
}

int tssh_sftp_rmdir(TsshSession* s, const char* path, char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || path == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  if (libssh2_sftp_rmdir(s->sftp, path) != 0) {
    return sftp_error(s, err, errlen, "rmdir failed");
  }
  return TSSH_OK;
}

int tssh_sftp_unlink(TsshSession* s, const char* path, char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || path == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  if (libssh2_sftp_unlink(s->sftp, path) != 0) {
    return sftp_error(s, err, errlen, "unlink failed");
  }
  return TSSH_OK;
}

int tssh_sftp_rename(TsshSession* s, const char* from, const char* to,
                     char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || from == NULL || to == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  if (libssh2_sftp_rename(s->sftp, from, to) != 0) {
    return sftp_error(s, err, errlen, "rename failed");
  }
  return TSSH_OK;
}

static int cancelled(void) {
  return g_cancel != 0;
}

int tssh_sftp_download(TsshSession* s, const char* remote, const char* local,
                       int64_t* out_bytes, char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || remote == NULL || local == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  g_cancel = 0;
  LIBSSH2_SFTP_HANDLE* handle =
      libssh2_sftp_open(s->sftp, remote, LIBSSH2_FXF_READ, 0);
  if (handle == NULL) {
    return sftp_error(s, err, errlen, "cannot open remote file");
  }
  FILE* out = fopen(local, "wb");
  if (out == NULL) {
    libssh2_sftp_close_handle(handle);
    set_err(err, errlen, "cannot create %s: %s", local, strerror(errno));
    return TSSH_ERR;
  }
  char* buffer = (char*)malloc(TSSH_IO_CHUNK);
  if (buffer == NULL) {
    fclose(out);
    libssh2_sftp_close_handle(handle);
    set_err(err, errlen, "out of memory");
    return TSSH_ERR;
  }
  int64_t total = 0;
  int result = TSSH_OK;
  for (;;) {
    if (cancelled()) {
      result = TSSH_ERR_CANCELLED;
      break;
    }
    ssize_t n = libssh2_sftp_read(handle, buffer, TSSH_IO_CHUNK);
    if (n == 0) {
      break;
    }
    if (n < 0) {
      sftp_error(s, err, errlen, "remote read failed");
      result = TSSH_ERR;
      break;
    }
    if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) {
      set_err(err, errlen, "local write failed: %s", strerror(errno));
      result = TSSH_ERR;
      break;
    }
    total += n;
  }
  free(buffer);
  if (fclose(out) != 0 && result == TSSH_OK) {
    set_err(err, errlen, "local close failed: %s", strerror(errno));
    result = TSSH_ERR;
  }
  libssh2_sftp_close_handle(handle);
  if (result != TSSH_OK) {
    unlink(local);
  } else if (out_bytes != NULL) {
    *out_bytes = total;
  }
  return result;
}

int tssh_sftp_upload(TsshSession* s, const char* local, const char* remote,
                     int64_t* out_bytes, char* err, int errlen) {
  if (s == NULL || s->sftp == NULL || remote == NULL || local == NULL) {
    set_err(err, errlen, "SFTP is not initialised");
    return TSSH_ERR;
  }
  g_cancel = 0;
  FILE* in = fopen(local, "rb");
  if (in == NULL) {
    set_err(err, errlen, "cannot open %s: %s", local, strerror(errno));
    return TSSH_ERR;
  }
  LIBSSH2_SFTP_HANDLE* handle = libssh2_sftp_open(
      s->sftp, remote,
      LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
      LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IRGRP |
          LIBSSH2_SFTP_S_IROTH);
  if (handle == NULL) {
    fclose(in);
    return sftp_error(s, err, errlen, "cannot create remote file");
  }
  char* buffer = (char*)malloc(TSSH_IO_CHUNK);
  if (buffer == NULL) {
    fclose(in);
    libssh2_sftp_close_handle(handle);
    set_err(err, errlen, "out of memory");
    return TSSH_ERR;
  }
  int64_t total = 0;
  int result = TSSH_OK;
  for (;;) {
    if (cancelled()) {
      result = TSSH_ERR_CANCELLED;
      break;
    }
    size_t n = fread(buffer, 1, TSSH_IO_CHUNK, in);
    if (n == 0) {
      if (ferror(in)) {
        set_err(err, errlen, "local read failed: %s", strerror(errno));
        result = TSSH_ERR;
      }
      break;
    }
    size_t off = 0;
    while (off < n) {
      ssize_t written = libssh2_sftp_write(handle, buffer + off, n - off);
      if (written < 0) {
        if (written == LIBSSH2_ERROR_EAGAIN) {
          continue;
        }
        sftp_error(s, err, errlen, "remote write failed");
        result = TSSH_ERR;
        break;
      }
      off += (size_t)written;
    }
    if (result != TSSH_OK) {
      break;
    }
    total += (int64_t)n;
  }
  free(buffer);
  fclose(in);
  libssh2_sftp_close_handle(handle);
  if (result != TSSH_OK) {
    libssh2_sftp_unlink(s->sftp, remote);
  } else if (out_bytes != NULL) {
    *out_bytes = total;
  }
  return result;
}

void tssh_cancel_transfers(int cancel) {
  g_cancel = cancel ? 1 : 0;
}
