#!/usr/bin/env python3
# Copyright (C) 2026 MC4HOS Contributors
# SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Configuration rules whose violations break hvigor or strip attribution.

  1. resources/**/*.json are STRICT JSON (restool rejects comments)
  2. no '#' comments in .json5 files
  3. modelVersion is consistent across oh-package and hvigor configs
  4. HarmonyOS SDK strings keep the "(api)" suffix and target >= compatible
  5. AppScope/app.json5 declares buildVersion (DevEco 6.x schema)
  6. app icons are real PNG files
  7. the native build targets arm64-v8a at minimum
  8. third-party fetches are URL + SHA-256 pinned, and their license texts
     are bundled in the HAP
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".hvigor", ".cxx", ".build", ".third_party",
             "node_modules", "oh_modules", "build"}
errors: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def read(rel: str) -> str:
    path = ROOT / rel
    return path.read_text(encoding="utf-8") if path.exists() else ""


# 1. strict JSON resources
resource_files = sorted(
    list(ROOT.glob("AppScope/resources/**/*.json"))
    + list(ROOT.glob("entry/src/main/resources/**/*.json"))
)
for path in resource_files:
    try:
        json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)}: not strict JSON "
             f"({exc.msg} at line {exc.lineno})")

# 2. '#' comments in json5
for path in sorted(ROOT.rglob("*.json5")):
    if set(path.relative_to(ROOT).parts) & SKIP_DIRS:
        continue
    for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            fail(f"{path.relative_to(ROOT)}:{lineno}: '#' comment "
                 "(JSON5 allows only //)")

# 3. modelVersion consistency
def model_version(rel: str) -> str | None:
    match = re.search(r'"modelVersion":\s*"([^"]+)"', read(rel))
    return match.group(1) if match else None


versions = {
    "oh-package.json5": model_version("oh-package.json5"),
    "hvigor/hvigor-config.json5": model_version("hvigor/hvigor-config.json5"),
}
declared = {name: version for name, version in versions.items() if version}
if not declared:
    fail("no modelVersion found in oh-package.json5 or hvigor config")
elif len(set(declared.values())) > 1:
    fail(f"modelVersion mismatch across configs: {declared}")
else:
    print(f"modelVersion: {next(iter(declared.values()))} (consistent)")

# 4. SDK version strings
build_profile = read("build-profile.json5")
sdk: dict[str, int] = {}
for key in ("compatibleSdkVersion", "targetSdkVersion"):
    match = re.search(rf'"{key}":\s*"([^"]+)"', build_profile)
    if not match:
        fail(f"build-profile.json5: {key} missing")
        continue
    value = match.group(1)
    parsed = re.fullmatch(r"(\d+\.\d+\.\d+)\((\d+)\)", value)
    if not parsed:
        fail(f'build-profile.json5: {key}="{value}" lacks the "(api)" suffix')
        continue
    sdk[key] = int(parsed.group(2))
if len(sdk) == 2 and sdk["targetSdkVersion"] < sdk["compatibleSdkVersion"]:
    fail("build-profile.json5: targetSdkVersion < compatibleSdkVersion")

# 5. buildVersion
if '"buildVersion"' not in read("AppScope/app.json5"):
    fail("AppScope/app.json5: missing required 'buildVersion'")

# 6. PNG app icons
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
for media in (ROOT / "AppScope/resources/base/media",
              ROOT / "entry/src/main/resources/base/media"):
    icon = media / "app_icon.png"
    if not icon.exists():
        fail(f"{icon.relative_to(ROOT)}: missing")
    elif not icon.read_bytes().startswith(PNG_MAGIC):
        fail(f"{icon.relative_to(ROOT)}: not a PNG file")

# 7. native ABIs
entry_profile = read("entry/build-profile.json5")
if '"arm64-v8a"' not in entry_profile:
    fail("entry/build-profile.json5: abiFilters must include arm64-v8a")

# 8. pinned third-party fetches + bundled licenses
cmake = read("entry/src/main/cpp/CMakeLists.txt")
for library in ("mbedtls-3.6.2", "libssh2-1.11.1"):
    if library not in cmake:
        fail(f"CMakeLists.txt: {library} pin missing")
if len(re.findall(r"URL_HASH\s+SHA256=[0-9a-f]{64}", cmake)) < 2:
    fail("CMakeLists.txt: both third-party archives need SHA-256 pins")
for name in ("LICENSE-MPL-2.0.txt", "LICENSE-libssh2.txt",
             "LICENSE-mbedtls.txt"):
    license_path = ROOT / "entry/src/main/resources/rawfile/licenses" / name
    if not license_path.exists() or license_path.stat().st_size < 500:
        fail(f"rawfile/licenses/{name}: missing or truncated")

if errors:
    print(f"FAIL: {len(errors)} config rule violation(s):")
    for error in errors:
        print("  -", error)
    sys.exit(1)

print(f"OK: {len(resource_files)} strict-JSON resources valid; all rules pass")
