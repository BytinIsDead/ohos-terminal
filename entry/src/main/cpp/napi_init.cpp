/*
 * Copyright (C) 2026 MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * NAPI surface for the SSH/SFTP bridge. Synchronous calls are limited to
 * channel I/O (non-blocking by design); connection setup, authentication and
 * SFTP operations run on libuv worker threads so the ArkTS UI never blocks.
 */

#include <napi/native_api.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "ssh_bridge.h"

namespace {

void Execute(napi_env env, void* data);
void Complete(napi_env env, napi_status status, void* data);

std::unordered_map<int, TsshSession*> g_sessions;
std::unordered_map<int, int> g_busy;
int g_next_handle = 1;

enum Op {
  OP_CONNECT,
  OP_AUTH_PASSWORD,
  OP_AUTH_KEY,
  OP_SHELL,
  OP_EXEC,
  OP_SFTP_INIT,
  OP_LIST,
  OP_STAT,
  OP_REALPATH,
  OP_MKDIR,
  OP_RMDIR,
  OP_UNLINK,
  OP_RENAME,
  OP_DOWNLOAD,
  OP_UPLOAD
};

struct Work {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  Op op = OP_CONNECT;
  int id = 0;
  int port = 0;
  int timeout = 0;
  int arg_i = 0;
  std::string s1;
  std::string s2;
  std::string s3;
  std::string s4;
  std::string result;
  TsshSession* session = nullptr;
  int64_t bytes = 0;
  int rc = TSSH_OK;
  char err[512] = {0};
};

bool get_string_arg(napi_env env, napi_value value, std::string* out) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return false;
  }
  std::vector<char> buf(len + 1, '\0');
  napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len);
  out->assign(buf.data(), len);
  return true;
}

bool get_int_arg(napi_env env, napi_value value, int* out) {
  return napi_get_value_int32(env, value, out) == napi_ok;
}

bool get_bool_arg(napi_env env, napi_value value, bool* out) {
  return napi_get_value_bool(env, value, out) == napi_ok;
}

std::string json_escape(const char* text) {
  std::string out;
  if (text == nullptr) {
    return out;
  }
  out.reserve(strlen(text) + 8);
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(text);
       *p != 0; ++p) {
    unsigned char c = *p;
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
        break;
    }
  }
  return out;
}

void entry_json(std::string* out, const TsshEntry& e) {
  const char* type = e.is_link ? "l" : (e.is_dir ? "d" : "f");
  if (!e.is_link && !e.is_dir && (e.mode & 0170000) != 0100000 &&
      (e.mode & 0170000) != 0) {
    type = "o";
  }
  out->append("{\"name\":\"");
  out->append(json_escape(e.name != nullptr ? e.name : ""));
  out->append("\",\"type\":\"");
  out->append(type);
  out->append("\",\"mode\":");
  out->append(std::to_string(e.mode));
  out->append(",\"size\":");
  out->append(std::to_string(e.size));
  out->append(",\"mtime\":");
  out->append(std::to_string(e.mtime));
  out->append(",\"atime\":");
  out->append(std::to_string(e.atime));
  out->append(",\"uid\":");
  out->append(std::to_string(e.uid));
  out->append(",\"gid\":");
  out->append(std::to_string(e.gid));
  out->append(",\"target\":");
  if (e.target != nullptr) {
    out->append("\"");
    out->append(json_escape(e.target));
    out->append("\"");
  } else {
    out->append("null");
  }
  out->append(",\"long\":");
  if (e.long_entry != nullptr) {
    out->append("\"");
    out->append(json_escape(e.long_entry));
    out->append("\"");
  } else {
    out->append("null");
  }
  out->append("}");
}

std::string dir_json(const TsshDir* dir) {
  std::string out = "{\"count\":";
  out += std::to_string(dir != nullptr ? dir->count : 0);
  out += ",\"entries\":[";
  for (int i = 0; dir != nullptr && i < dir->count; i++) {
    if (i > 0) {
      out += ",";
    }
    entry_json(&out, dir->entries[i]);
  }
  out += "]}";
  return out;
}

std::string stat_json(const TsshEntry& entry) {
  std::string out;
  entry_json(&out, entry);
  return out;
}

napi_value make_error(napi_env env, const std::string& message) {
  napi_value text = nullptr;
  napi_value error = nullptr;
  napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &text);
  napi_create_error(env, nullptr, text, &error);
  return error;
}

napi_value reject_now(napi_env env, const std::string& message) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  napi_create_promise(env, &deferred, &promise);
  napi_reject_deferred(env, deferred, make_error(env, message));
  return promise;
}

napi_value queue_work(napi_env env, Work* w) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  napi_create_promise(env, &deferred, &promise);
  w->deferred = deferred;
  napi_value name = nullptr;
  napi_create_string_utf8(env, "terminal_core", NAPI_AUTO_LENGTH, &name);
  napi_create_async_work(env, nullptr, name, Execute, Complete, w, &w->work);
  napi_queue_async_work(env, w->work);
  return promise;
}

void discard_work(Work* w) {
  if (w->id > 0) {
    auto it = g_busy.find(w->id);
    if (it != g_busy.end() && it->second > 0) {
      it->second--;
    }
  }
  delete w;
}

void resolve_work(napi_env env, Work* w) {
  napi_value value = nullptr;
  if (w->rc != TSSH_OK) {
    const char* message = w->rc == TSSH_ERR_CANCELLED
                              ? "transfer cancelled"
                              : (w->err[0] != 0 ? w->err : "operation failed");
    napi_reject_deferred(env, w->deferred, make_error(env, message));
    return;
  }
  switch (w->op) {
    case OP_CONNECT: {
      int handle = g_next_handle++;
      g_sessions[handle] = w->session;
      w->session = nullptr;
      TsshSession* s = g_sessions[handle];
      char type[64];
      char fingerprint[64];
      tssh_hostkey(s, type, sizeof(type), fingerprint, sizeof(fingerprint));
      const char* banner = tssh_banner(s);
      w->result = "{\"id\":" + std::to_string(handle) +
                  ",\"hostKeyType\":\"" + json_escape(type) +
                  "\",\"fingerprint\":\"" + json_escape(fingerprint) +
                  "\",\"banner\":\"" + json_escape(banner) + "\"}";
      napi_create_string_utf8(env, w->result.c_str(), NAPI_AUTO_LENGTH, &value);
      break;
    }
    case OP_LIST:
    case OP_STAT:
    case OP_REALPATH:
      napi_create_string_utf8(env, w->result.c_str(), NAPI_AUTO_LENGTH, &value);
      break;
    case OP_DOWNLOAD:
    case OP_UPLOAD:
      napi_create_double(env, static_cast<double>(w->bytes), &value);
      break;
    default:
      napi_get_undefined(env, &value);
      break;
  }
  napi_resolve_deferred(env, w->deferred, value);
}

void Execute(napi_env env, void* data) {
  (void)env;
  Work* w = static_cast<Work*>(data);
  w->err[0] = '\0';
  switch (w->op) {
    case OP_CONNECT: {
      TsshSession* session = tssh_connect(w->s1.c_str(), w->port, w->timeout,
                                          w->err, sizeof(w->err));
      if (session == nullptr) {
        w->rc = TSSH_ERR;
      } else {
        w->session = session;
        w->rc = TSSH_OK;
      }
      break;
    }
    case OP_AUTH_PASSWORD:
      w->rc = tssh_auth_password(w->session, w->s1.c_str(), w->s2.c_str(),
                                 w->err, sizeof(w->err));
      break;
    case OP_AUTH_KEY:
      w->rc = tssh_auth_key(w->session, w->s1.c_str(), w->s2.c_str(),
                            w->s3.c_str(), w->s4.c_str(), w->err,
                            sizeof(w->err));
      break;
    case OP_SHELL:
      w->rc = tssh_start_shell(w->session, w->arg_i,
                               w->port > 0 ? w->port : 24, w->err,
                               sizeof(w->err));
      break;
    case OP_EXEC:
      w->rc = tssh_start_exec(w->session, w->s1.c_str(), w->arg_i, 24, w->err,
                              sizeof(w->err));
      break;
    case OP_SFTP_INIT:
      w->rc = tssh_sftp_init(w->session, w->err, sizeof(w->err));
      break;
    case OP_LIST: {
      TsshDir* dir = tssh_sftp_list(w->session, w->s1.c_str(), w->err,
                                    sizeof(w->err));
      if (dir == nullptr) {
        w->rc = TSSH_ERR;
      } else {
        w->result = dir_json(dir);
        tssh_dir_free(dir);
        w->rc = TSSH_OK;
      }
      break;
    }
    case OP_STAT: {
      TsshEntry entry;
      memset(&entry, 0, sizeof(entry));
      int rc = tssh_sftp_stat(w->session, w->s1.c_str(), w->arg_i, &entry,
                              w->err, sizeof(w->err));
      if (rc == TSSH_OK) {
        w->result = stat_json(entry);
        tssh_entry_free(&entry);
      }
      w->rc = rc;
      break;
    }
    case OP_REALPATH: {
      char resolved[4096];
      resolved[0] = '\0';
      w->rc = tssh_sftp_realpath(w->session, w->s1.c_str(), resolved,
                                 sizeof(resolved));
      if (w->rc == TSSH_OK) {
        w->result.assign(resolved);
      }
      break;
    }
    case OP_MKDIR:
      w->rc = tssh_sftp_mkdir(w->session, w->s1.c_str(), w->arg_i, w->err,
                              sizeof(w->err));
      break;
    case OP_RMDIR:
      w->rc = tssh_sftp_rmdir(w->session, w->s1.c_str(), w->err,
                              sizeof(w->err));
      break;
    case OP_UNLINK:
      w->rc = tssh_sftp_unlink(w->session, w->s1.c_str(), w->err,
                               sizeof(w->err));
      break;
    case OP_RENAME:
      w->rc = tssh_sftp_rename(w->session, w->s1.c_str(), w->s2.c_str(),
                               w->err, sizeof(w->err));
      break;
    case OP_DOWNLOAD:
      w->rc = tssh_sftp_download(w->session, w->s1.c_str(), w->s2.c_str(),
                                 &w->bytes, w->err, sizeof(w->err));
      break;
    case OP_UPLOAD:
      w->rc = tssh_sftp_upload(w->session, w->s1.c_str(), w->s2.c_str(),
                               &w->bytes, w->err, sizeof(w->err));
      break;
    default:
      w->rc = TSSH_ERR;
      snprintf(w->err, sizeof(w->err), "unknown operation");
      break;
  }
}

void Complete(napi_env env, napi_status status, void* data) {
  Work* w = static_cast<Work*>(data);
  if (w->id > 0) {
    auto it = g_busy.find(w->id);
    if (it != g_busy.end() && it->second > 0) {
      it->second--;
    }
  }
  if (status != napi_ok) {
    napi_reject_deferred(env, w->deferred,
                         make_error(env, "native work item failed"));
  } else {
    resolve_work(env, w);
  }
  if (w->session != nullptr && w->op == OP_CONNECT) {
    tssh_close(w->session);
    w->session = nullptr;
  }
  if (w->work != nullptr) {
    napi_delete_async_work(env, w->work);
  }
  delete w;
}

TsshSession* lookup(int id) {
  auto it = g_sessions.find(id);
  return it == g_sessions.end() ? nullptr : it->second;
}

Work* work_for(napi_env env, napi_value* argv, int* id_out) {
  int id = 0;
  if (napi_get_value_int32(env, argv[0], &id) != napi_ok) {
    return nullptr;
  }
  TsshSession* session = lookup(id);
  if (session == nullptr) {
    return nullptr;
  }
  Work* w = new Work();
  w->id = id;
  w->session = session;
  *id_out = id;
  g_busy[id]++;
  return w;
}

napi_value Connect(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "connect(host, port, timeoutMs)");
  }
  Work* w = new Work();
  w->op = OP_CONNECT;
  if (!get_string_arg(env, argv[0], &w->s1) ||
      !get_int_arg(env, argv[1], &w->port) ||
      !get_int_arg(env, argv[2], &w->timeout)) {
    discard_work(w);
    return reject_now(env, "invalid connect arguments");
  }
  return queue_work(env, w);
}

napi_value AuthPassword(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "authPassword(id, user, password)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_AUTH_PASSWORD;
  if (!get_string_arg(env, argv[1], &w->s1) ||
      !get_string_arg(env, argv[2], &w->s2)) {
    discard_work(w);
    return reject_now(env, "invalid authentication arguments");
  }
  return queue_work(env, w);
}

napi_value AuthKey(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value argv[5];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 5) {
    return reject_now(env, "authKey(id, user, publicKey, privateKey, passphrase)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_AUTH_KEY;
  if (!get_string_arg(env, argv[1], &w->s1) ||
      !get_string_arg(env, argv[2], &w->s2) ||
      !get_string_arg(env, argv[3], &w->s3) ||
      !get_string_arg(env, argv[4], &w->s4)) {
    discard_work(w);
    return reject_now(env, "invalid key authentication arguments");
  }
  return queue_work(env, w);
}

napi_value StartShell(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "startShell(id, cols, rows)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_SHELL;
  if (!get_int_arg(env, argv[1], &w->arg_i) ||
      !get_int_arg(env, argv[2], &w->port)) {
    discard_work(w);
    return reject_now(env, "invalid size arguments");
  }
  return queue_work(env, w);
}

napi_value StartExec(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    return reject_now(env, "startExec(id, command)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_EXEC;
  if (!get_string_arg(env, argv[1], &w->s1)) {
    discard_work(w);
    return reject_now(env, "invalid command");
  }
  w->arg_i = 80;
  return queue_work(env, w);
}

napi_value OpenSftp(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_SFTP_INIT;
  return queue_work(env, w);
}

napi_value SftpList(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    return reject_now(env, "sftpList(id, path)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_LIST;
  if (!get_string_arg(env, argv[1], &w->s1)) {
    discard_work(w);
    return reject_now(env, "invalid path");
  }
  return queue_work(env, w);
}

napi_value SftpStat(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "sftpStat(id, path, follow)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_STAT;
  bool follow = false;
  if (!get_string_arg(env, argv[1], &w->s1) ||
      !get_bool_arg(env, argv[2], &follow)) {
    discard_work(w);
    return reject_now(env, "invalid stat arguments");
  }
  w->arg_i = follow ? 1 : 0;
  return queue_work(env, w);
}

napi_value SftpRealpath(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    return reject_now(env, "sftpRealpath(id, path)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_REALPATH;
  if (!get_string_arg(env, argv[1], &w->s1)) {
    discard_work(w);
    return reject_now(env, "invalid path");
  }
  return queue_work(env, w);
}

napi_value SimpleOp(napi_env env, napi_callback_info info, Op op,
                    bool has_mode, bool has_second_path) {
  size_t argc = has_second_path ? 3 : (has_mode ? 3 : 2);
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    return reject_now(env, "missing arguments");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = op;
  if (!get_string_arg(env, argv[1], &w->s1)) {
    discard_work(w);
    return reject_now(env, "invalid path");
  }
  if (has_mode && argc > 2) {
    get_int_arg(env, argv[2], &w->arg_i);
  }
  if (has_second_path && argc > 2) {
    if (!get_string_arg(env, argv[2], &w->s2)) {
      discard_work(w);
      return reject_now(env, "invalid target path");
    }
  }
  return queue_work(env, w);
}

napi_value SftpMkdir(napi_env env, napi_callback_info info) {
  return SimpleOp(env, info, OP_MKDIR, true, false);
}
napi_value SftpRmdir(napi_env env, napi_callback_info info) {
  return SimpleOp(env, info, OP_RMDIR, false, false);
}
napi_value SftpUnlink(napi_env env, napi_callback_info info) {
  return SimpleOp(env, info, OP_UNLINK, false, false);
}
napi_value SftpRename(napi_env env, napi_callback_info info) {
  return SimpleOp(env, info, OP_RENAME, false, true);
}

napi_value SftpDownload(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "sftpDownload(id, remote, local)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_DOWNLOAD;
  if (!get_string_arg(env, argv[1], &w->s1) ||
      !get_string_arg(env, argv[2], &w->s2)) {
    discard_work(w);
    return reject_now(env, "invalid download arguments");
  }
  return queue_work(env, w);
}

napi_value SftpUpload(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    return reject_now(env, "sftpUpload(id, local, remote)");
  }
  int id = 0;
  Work* w = work_for(env, argv, &id);
  if (w == nullptr) {
    return reject_now(env, "invalid session handle");
  }
  w->op = OP_UPLOAD;
  if (!get_string_arg(env, argv[1], &w->s1) ||
      !get_string_arg(env, argv[2], &w->s2)) {
    discard_work(w);
    return reject_now(env, "invalid upload arguments");
  }
  return queue_work(env, w);
}

napi_value Write(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int32_t result = -1;
  int id = 0;
  if (argc >= 2 && napi_get_value_int32(env, argv[0], &id) == napi_ok) {
    TsshSession* session = lookup(id);
    void* data = nullptr;
    size_t len = 0;
    if (session != nullptr &&
        napi_get_arraybuffer_info(env, argv[1], &data, &len) == napi_ok &&
        len > 0) {
      long n = tssh_write(session, static_cast<const uint8_t*>(data),
                          static_cast<int>(len));
      result = n < 0 ? -1 : static_cast<int32_t>(n);
    }
  }
  napi_value out = nullptr;
  napi_create_int32(env, result, &out);
  return out;
}

napi_value ReadCommon(napi_env env, napi_callback_info info, bool stderr_stream) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  int cap = 0;
  if (argc >= 2 && napi_get_value_int32(env, argv[0], &id) == napi_ok &&
      napi_get_value_int32(env, argv[1], &cap) == napi_ok && cap > 0) {
    if (cap > 65536) {
      cap = 65536;
    }
    TsshSession* session = lookup(id);
    if (session != nullptr) {
      std::vector<uint8_t> buffer(static_cast<size_t>(cap));
      long n = stderr_stream ? tssh_read_stderr(session, buffer.data(), cap)
                             : tssh_read(session, buffer.data(), cap);
      if (n > 0) {
        napi_value out = nullptr;
        void* raw = nullptr;
        napi_create_arraybuffer(env, static_cast<size_t>(n), &raw, &out);
        memcpy(raw, buffer.data(), static_cast<size_t>(n));
        return out;
      }
    }
  }
  napi_value empty = nullptr;
  void* raw = nullptr;
  napi_create_arraybuffer(env, 0, &raw, &empty);
  return empty;
}

napi_value Read(napi_env env, napi_callback_info info) {
  return ReadCommon(env, info, false);
}

napi_value ReadStderr(napi_env env, napi_callback_info info) {
  return ReadCommon(env, info, true);
}

napi_value Resize(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  int cols = 0;
  int rows = 0;
  if (argc >= 3 && napi_get_value_int32(env, argv[0], &id) == napi_ok &&
      napi_get_value_int32(env, argv[1], &cols) == napi_ok &&
      napi_get_value_int32(env, argv[2], &rows) == napi_ok) {
    TsshSession* session = lookup(id);
    if (session != nullptr) {
      tssh_resize(session, cols, rows);
    }
  }
  return nullptr;
}

napi_value IsEof(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  bool eof = true;
  if (argc >= 1 && napi_get_value_int32(env, argv[0], &id) == napi_ok) {
    TsshSession* session = lookup(id);
    if (session != nullptr) {
      eof = tssh_eof(session) != 0;
    }
  }
  napi_value out = nullptr;
  napi_get_boolean(env, eof, &out);
  return out;
}

napi_value ExitStatus(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  int status = -1;
  if (argc >= 1 && napi_get_value_int32(env, argv[0], &id) == napi_ok) {
    TsshSession* session = lookup(id);
    if (session != nullptr) {
      status = tssh_exit_status(session);
    }
  }
  napi_value out = nullptr;
  napi_create_int32(env, status, &out);
  return out;
}

napi_value Close(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int id = 0;
  bool closed = false;
  if (argc >= 1 && napi_get_value_int32(env, argv[0], &id) == napi_ok) {
    auto busy = g_busy.find(id);
    if (busy == g_busy.end() || busy->second <= 0) {
      auto it = g_sessions.find(id);
      if (it != g_sessions.end()) {
        tssh_cancel_transfers(1);
        tssh_close(it->second);
        g_sessions.erase(it);
        closed = true;
      }
    }
  }
  napi_value out = nullptr;
  napi_get_boolean(env, closed, &out);
  return out;
}

napi_value CancelTransfers(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  bool cancel = true;
  if (argc >= 1) {
    napi_get_value_bool(env, argv[0], &cancel);
  }
  tssh_cancel_transfers(cancel ? 1 : 0);
  return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"authPassword", nullptr, AuthPassword, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"authKey", nullptr, AuthKey, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"startShell", nullptr, StartShell, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"startExec", nullptr, StartExec, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"write", nullptr, Write, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"read", nullptr, Read, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"readStderr", nullptr, ReadStderr, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"resize", nullptr, Resize, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"isEof", nullptr, IsEof, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"exitStatus", nullptr, ExitStatus, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"openSftp", nullptr, OpenSftp, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"sftpList", nullptr, SftpList, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"sftpStat", nullptr, SftpStat, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"sftpRealpath", nullptr, SftpRealpath, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sftpMkdir", nullptr, SftpMkdir, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"sftpRmdir", nullptr, SftpRmdir, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"sftpUnlink", nullptr, SftpUnlink, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sftpRename", nullptr, SftpRename, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sftpDownload", nullptr, SftpDownload, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sftpUpload", nullptr, SftpUpload, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"cancelTransfers", nullptr, CancelTransfers, nullptr, nullptr, nullptr,
       napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

}  // namespace

NAPI_MODULE(terminal_core, Init)
