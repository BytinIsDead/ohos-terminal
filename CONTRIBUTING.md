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

## Before sending a change

```sh
python3 scripts/check_mpl_headers.py
python3 scripts/check_configs.py
cd tests && npm test
```

Then build the HAP (`scripts/build_hap.bat` on Windows or
`scripts/build_hap.sh` elsewhere). CI runs the same checks plus a full
unsigned build.

## Adding terminal features

- Emulator changes belong in `entry/src/main/ets/core/ansi/` with tests in
  `tests/core/vt.test.mjs`.
- Shell builtins live in `entry/src/main/ets/core/shell/Shell.ets` and
  must only use the `ShellFs` interface.
- Native changes go through `entry/src/main/cpp/src/ssh_bridge.c` and
  `napi_init.cpp`; keep the Promise-based N-API surface in
  `types/libterminal_core/index.d.ts` in sync.
