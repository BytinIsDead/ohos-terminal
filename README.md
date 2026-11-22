# OHOS Terminal

[![CI](https://github.com/BytinIsDead/ohos-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/BytinIsDead/ohos-terminal/actions/workflows/ci.yml)

A terminal and SSH client for HarmonyOS (API 24, DevEco Studio 6.1.1).
Clean-room ArkTS + a small N-API core around libssh2 and mbedTLS. No
JavaScript runtimes, no WebView, no shell process.

The file manager moved to a separate app:
[BytinIsDead/ohos-archiver](https://github.com/BytinIsDead/ohos-archiver).

![app icon](AppScope/resources/base/media/app_icon.png)

## Features

**Terminal**
- Tabbed sessions: any number of in-app local shells plus SSH sessions.
- VT100/xterm emulation: UTF-8, CSI/OSC parsing, 16/256/truecolor SGR,
  alternate screen, scrollback, deferred wrap, bracketed paste, DSR/DA.
- Local sandbox shell implemented in ArkTS: `ls cd pwd cat echo mkdir rmdir
  rm mv cp touch head tail wc grep sort stat du df date uname hostname
  whoami id env history clear help true false sleep tee`.
  Quoting, `\` escapes, `$VAR`/`${VAR}`/`$?`, `~`, globs, pipelines (`|`),
  redirection (`> >> <`), `;` chaining, tab completion and history.
- SSH shell: RFC 4254 channel, PTY request, window resize, non-blocking
  reads. Password and private-key auth (with optional passphrase).
- TOFU host-key pinning: the SHA-256 fingerprint is shown and must be
  accepted before any credential is sent; later mismatches are rejected.

**Storage mounts**
- With the Download and Documents permissions granted at runtime, the
  local shell exposes them as `/download` and `/documents`, so commands
  like `ls /download`, `cp`, `cat` and `stat` work on real user files.
- Everything else stays in the private app sandbox (`/`).

**Profiles and secrets**
- Host profiles (name, host, port, user, auth, key paths, pinned
  fingerprint, remote start directory) stored in Preferences.
- Passwords and key passphrases stored with the Asset Store Kit
  (`@ohos.security.asset`), never in plain preferences.
- Private keys are imported through the system file picker into the app's
  `/keys` directory.

## Requirements

- HarmonyOS SDK 6.1.1 (API 24), DevEco Studio 6.1.1 or the matching
  command-line tools.
- For the native core: network access at first configure to download
  libssh2 1.11.1 and mbedTLS 3.6.2 (both pinned by SHA-256), or a
  pre-populated `.third_party` directory with `OHTERM_OFFLINE=1`.

## Build

Windows:

```bat
scripts\build_hap.bat
```

Linux/macOS (DevEco Studio or commandline-tools):

```sh
scripts/build_hap.sh
```

The unsigned HAP is copied to `out/`. Release signing stays a manual local
step in DevEco Studio.

## Tests

Pure ArkTS core logic (terminal emulator, shell, paths, formatting, key
handling) runs under Node 24, which strips TypeScript types natively:

```sh
cd tests && npm test
```

The harness copies `entry/src/main/ets/core/**/*.ets` into `tests/.build`
and rewrites relative imports, so the same sources run in tests and in the
app.

## Layout

```
entry/src/main/ets/
  common/     ArkTS-safe JSON access, logging
  core/       pure logic: ansi/, fs/, shell/  (no HarmonyOS imports)
  fs/         LocalFs: ShellFs over the app sandbox
  services/   paths, profile store, secret store
  session/    local and SSH terminal sessions
  ssh/        N-API wrapper for the native SSH core
  ui/         terminal canvas, key bar
  pages/      tab shell, host manager, dialogs
entry/src/main/cpp/
  napi_init.cpp, src/ssh_bridge.c   libssh2 + mbedTLS bridge
  CMakeLists.txt                    pinned FetchContent build
tests/        Node test harness
docs/         build, security and contribution notes
```

## Security notes

- The local shell is virtual: paths stay inside the app sandbox, except
  the opt-in `/download` and `/documents` mounts backed by the public user
  folders. There is no `exec` and no device shell.
- Host keys are pinned per profile (SHA-256). Changing `known_hosts`
  semantics deliberately: a mismatch is a hard stop.
- Secrets use the system Asset Store (`@ohos.security.asset`), with
  passwords/passphrases keyed per profile.
- See [docs/SECURITY.md](docs/SECURITY.md) for the full model and known
  limitations.

## Limitations

- The soft keyboard does not expose raw key events on HarmonyOS, so
  character input is line-based (`TextInput` + Enter). Single-key TUI
  interaction uses the on-screen key bar (Esc/Tab/arrows/PgUp/PgDn/F-keys/
  Ctrl-C/D/L/Z); a hardware keyboard sends real key events.
- No port forwarding, agent forwarding, X11, mosh or terminal multiplexing.
- Storage mounts appear only when the runtime request is granted; the
  Desktop folder needs a system-level permission and is not mounted.
- The app ships no GPL components and no proprietary assets.

## License

MPL-2.0 with Exhibit B ("no copyleft exception"), SPDX
`MPL-2.0-no-copyleft-exception`. Third-party notices and license texts are
in [NOTICE.md](NOTICE.md) and bundled in the HAP under
`resources/rawfile/licenses/`.
