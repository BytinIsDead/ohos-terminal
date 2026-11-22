# Security model

## Scope

OHOS Terminal provides:

- a **virtual local shell** over the application sandbox (no process
  execution, no device shell), plus read/write mounts for the public
  Download and Documents folders when the user grants storage access;
- an **SSH client** (libssh2 + mbedTLS) with an interactive shell channel.

The app requests `ohos.permission.INTERNET` plus the normal-level,
user-granted `READ_WRITE_DOWNLOAD_DIRECTORY` and
`READ_WRITE_DOCUMENTS_DIRECTORY` permissions. The storage request is shown
at first launch; declining it simply hides `/download` and `/documents`.

## Local sandbox confinement

`LocalFs` maps the virtual POSIX root `/` to the app's `filesDir`. Every
requested path is normalized first (`PathUtil.normalizePath`/`resolvePath`);
`..` clamps at `/`. Paths under `/download` and `/documents` are mapped to
the public user folders returned by `@ohos.file.environment`; those two
folders exist only when the corresponding permission was granted. The
shell (`core/shell/Shell.ets`) only sees the `ShellFs` interface and never
touches the device filesystem directly.

## Credential handling

- **Host keys**: the native layer reports the server's SHA-256 host-key
  fingerprint after the handshake and *before* authentication. The UI shows
  it for first use (trust on first use). The accepted fingerprint is stored
  in the profile; any later mismatch aborts the connection. There is no
  "ignore" option.
- **Passwords and passphrases**: stored with the Asset Store Kit
  (`@ohos.security.asset`), keyed by profile id
  (`ohterm.ssh.password.<id>`, `ohterm.ssh.passphrase.<id>`). They are not
  written to Preferences, logs, or the HAP.
- **Private keys**: imported via the system document picker and copied into
  the app sandbox (`/keys`). Paths are stored per profile.
- The native core receives credentials per connection and does not persist
  them.
- `SshProfile` deliberately exposes no `toJson`; profile persistence is
  limited to non-secret fields in `ProfileStore`.

## Transport

- SSH runs through libssh2 1.11.1 with mbedTLS 3.6.2, both pinned by
  SHA-256 at build time and linked statically.
- The default port is 22; the port is configurable per profile.
- The shell uses a non-blocking SSH channel, so UI input and rendering
  never wait on the network.
- The separately published archiver app has no network permission at all.

## Secrets in memory and logs

- The logger (`common/Logger.ets`) writes hilog messages that contain
  state transitions and error strings, never passwords or key material.
- The terminal emulator can display whatever the remote sends, including
  secrets the user types into the remote shell. Screen contents are not
  persisted by the app.

## Known limitations

- TOFU means the first connection to a host is unauthenticated by
  definition; verify the fingerprint out of band if that matters.
- The terminal soft keyboard is line-based. Single-key interaction uses
  the key bar. There is no terminal-level clipboard history.
- SFTP transfers, port forwarding, agent forwarding and X11 are not part
  of the terminal app; use `ohos-archiver` for local file management.
- The unsigned CI artifact must be signed locally before installation.
- No device testing has been performed by the maintainers for every vendor
  build; treat it as beta software.

## Reporting

Open a private security advisory on GitHub:
<https://github.com/BytinIsDead/ohos-terminal/security/advisories/new>.
Please do not file public issues for exploitable problems before a fix is
available.
