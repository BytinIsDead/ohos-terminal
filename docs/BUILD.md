# Build notes

Everything here is verified against DevEco Studio 6.1.1 (HarmonyOS SDK
6.1.1, API 24). The app has no repository secrets or variables; CI uses
public, login-free toolchain downloads.

## 1. Toolchain layouts

Two layouts are supported, and `scripts/build_hap.sh` detects both:

| Layout | hvigor engine | node | SDK |
| --- | --- | --- | --- |
| DevEco Studio | `<home>/tools/hvigor/bin/hvigorw.js` | `<home>/tools/node/bin/node` | `<home>/sdk` |
| commandline-tools zip | `<home>/hvigor/bin/hvigorw.js` | `<home>/tool/node/bin/node` | `<home>/sdk` |

The zip's root directory is hyphenated (`command-line-tools/`). Scripts
derive the toolchain root from the discovered `hvigorw.js`, so the name
does not matter. Set `DEVECO_STUDIO_HOME` to override discovery.

On Windows, `scripts/build_hap.bat` assumes the DevEco Studio layout at
`C:\Program Files\Huawei\DevEco Studio` unless `DEVECO_STUDIO_HOME` is set.

## 2. Local build

```bat
scripts\build_hap.bat
```

or

```sh
scripts/build_hap.sh
```

The scripts:

1. run `ohpm install` when ohpm is available;
2. invoke `hvigorw --mode module -p module=entry@default -p product=default
   assembleHap`;
3. copy the unsigned HAP to `out/`.

A clean native build takes several minutes: libssh2 and mbedTLS are
downloaded once per CMake build tree and compiled for `arm64-v8a` and
`x86_64`.

## 3. Native core

`entry/src/main/cpp/CMakeLists.txt` is driven by hvigor's
`externalNativeOptions`. Pins:

| Component | Version | Archive SHA-256 |
| --- | --- | --- |
| mbedTLS | 3.6.2 | `8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca` |
| libssh2 | 1.11.1 | `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7` |

Sources are fetched with CMake `FetchContent` into `.third_party/`
(gitignored). To reuse an existing checkout without network access:

```sh
export OHTERM_OFFLINE=1
```

`entry/build-profile.json5` builds both `arm64-v8a` and `x86_64`.

### Known CMake trap

libssh2 1.11.1 calls `install(EXPORT ...)` on its static target. If that
target links a build-tree target from another project, CMake fails with
"requires target mbedcrypto that is not in any export set". The build
therefore points libssh2's `FindMbedTLS` at the mbedcrypto **archive path**
(`MBEDCRYPTO_LIBRARY`), which is exportable, instead of the `mbedcrypto`
target name.

## 4. Tests

```sh
cd tests
npm test
```

Node 24 runs the ArkTS core directly by stripping types. The harness copies
`entry/src/main/ets/core/**/*.ets` to `tests/.build/core/*.ts` and rewrites
relative imports with a `.ts` suffix. Do not edit `tests/.build`; it is
generated and ignored.

## 5. CI

`.github/workflows/ci.yml` has two jobs:

- **verify** — SPDX headers, configuration rules, and the Node test suite.
- **build** — downloads `commandline-tools-linux-x64-6.1.1.280.zip` from a
  public Hugging Face mirror (revision-pinned, with a `main` fallback),
  installs oh_modules, builds the unsigned HAP, and uploads it as an
  artifact. The toolchain zip URL can be overridden with the repository
  variable `HOS_TOOLS_URL`.

CI artifacts are unsigned. To install a release build, sign it locally in
DevEco Studio (Project Structure → Signing Configs).

## 6. Common failures

| Symptom | Cause / fix |
| --- | --- |
| `hvigorw.js not found` | Wrong toolchain root; set `DEVECO_STUDIO_HOME`. |
| CMake export error mentioning `mbedcrypto` | Old build tree from before the archive-path fix; delete `entry/.cxx` and rebuild. |
| `ohpm install` fails offline | Populate `oh_modules` once with network access. |
| SDK mismatch (`6.1.1(24)`) | Install SDK 6.1.1 / API 24 and keep the `(api)` suffix in `build-profile.json5`. |
