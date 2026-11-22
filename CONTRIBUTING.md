# Contributing

## License

This project is MPL-2.0 with Exhibit B, SPDX
`MPL-2.0-no-copyleft-exception`. By contributing you agree that your
changes are licensed under the same terms.

Every source file must start with:

```ts
/**
 * Copyright (C) <year> MC4HOS Contributors
 * SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
```

JSON5, YAML, shell and batch files use the matching comment syntax. Run
`python3 scripts/check_mpl_headers.py` before committing.

## Clean-room rules

- No code copied from other terminal or launcher projects.
- No Minecraft, Mojang, Microsoft or other proprietary code or assets.
- Do not commit third-party sources or binaries. The native build fetches
  pinned archives at configure time; licenses live in
  `entry/src/main/resources/rawfile/licenses/`.
- Do not commit build output (`build/`, `.cxx/`, `out/`, `oh_modules/`,
  `tests/.build/`).

## ArkTS rules

The app targets the strict ArkTS subset used by API 24:

- no `any`, no index signatures, no enums;
- JSON is read through `common/JsonReader.ets` helpers;
- UI state uses `@State`/`@Link`/`@Prop` with explicit types;
- logic in `entry/src/main/ets/core/` must not import HarmonyOS modules,
  so it stays testable under Node.

## AI-assisted contributions

AI tools are allowed, with conditions:

- **You own the change.** Read, understand and be able to explain every line
  you submit. You are responsible for its correctness, licensing and security.
- **Verify APIs, flags and paths** against the installed SDK or upstream
  documentation. Generated code that merely looks plausible is not evidence.
- **Disclose AI assistance** in the PR description (tool and extent). Using AI
  is fine; submitting unreviewed output is not.
- **Do not paste secrets, keys, tokens, account data, proprietary or
  decompiled code, or third-party assets** into AI tools. SSH keys, host
  fingerprints and server details stay local.
- AI output follows the same clean-room, license-header and testing rules as
  hand-written code.

## Testing before every commit (required)

A runtime change that has not been tested on real hardware or an emulator must
not be committed.

Before committing any code, native, resource or configuration change:

1. Build the HAP (`scripts/build_hap.bat` / `.sh`) and fix every error.
2. Install and run it on a **real HarmonyOS device or an emulator**.
3. Exercise the feature you changed, including at least one failure or edge
   path, and smoke-test the core flows (local shell, SSH login, input).
4. Include the device/emulator model, API version, steps and result in the PR
   description. "It compiles" and "CI passed" are not testing.

Documentation-only commits are exempt from device testing but still must pass
the header and config checks. If you cannot test, **do not commit** — ask a
maintainer or another contributor to test first.

Useful device checklist:

- local shell starts, `ls`, `cd`, pipes and Ctrl-C behave;
- SSH password auth and key auth both connect;
- a new host key is shown before any credential is sent, and a changed
  pinned key is rejected;
- terminal resize, paste, and Ctrl/Alt key combinations reach the remote;
- `/download` and `/documents` mounts work when storage is granted and are
  absent when it is denied;
- closing the app and reconnecting leaves no stuck session.

## Strict commit rules

- `main` must build and pass all checks at every commit. Never push a broken
  commit with the intention of fixing it later.
- One logical change per commit. Do not mix refactors, features and fixes, and
  do not include unrelated formatting or drive-by edits.
- Never bypass hooks or CI: no `--no-verify`, no skipped tests, no disabled
  checks. Fix the root cause.
- Commit no build output, dependencies, caches, secrets, keys, tokens,
  third-party binaries or game assets.
- Never force-push or rewrite history on `main`. If a commit is wrong, revert
  it with a new commit; do not layer hacks on top.
- Stage files by name and review `git diff --staged` plus `git status` before
  committing.
- Preserve license headers and notices. Changes to licensing, permissions or
  the build configuration require maintainer agreement.
- Update tests and documentation in the same commit as the behaviour change.
- Keep the N-API surface in `types/libterminal_core/index.d.ts` in sync with
  native changes in the same commit.
- When unsure, stop and open an issue instead of guessing.

## Before sending a change

```sh
python3 scripts/check_mpl_headers.py
python3 scripts/check_configs.py
cd tests && npm test
```

Then build the HAP (`scripts/build_hap.bat` on Windows or
`scripts/build_hap.sh` elsewhere) and run the device checklist above. CI runs
the same checks plus a full unsigned build, but CI alone does not replace
device testing.

## Adding terminal features

- Emulator changes belong in `entry/src/main/ets/core/ansi/` with tests in
  `tests/core/vt.test.mjs`.
- Shell builtins live in `entry/src/main/ets/core/shell/Shell.ets` and
  must only use the `ShellFs` interface.
- Native changes go through `entry/src/main/cpp/src/ssh_bridge.c` and
  `napi_init.cpp`; keep the Promise-based N-API surface in
  `types/libterminal_core/index.d.ts` in sync.
