#!/usr/bin/env python3
# Copyright (C) 2026 MC4HOS Contributors
# SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Verify every first-party source file carries the Exhibit A notice.

The MPL-2.0 Exhibit B form requires the SPDX identifier
"MPL-2.0-no-copyleft-exception" and the Exhibit A boilerplate. Generated
lock files and third-party license texts are exempt.
"""

from __future__ import annotations

import sys
from pathlib import Path

SPDX = "SPDX-License-Identifier: MPL-2.0-no-copyleft-exception"
BOILERPLATE = "This Source Code Form is subject to the terms of the Mozilla Public"

SUFFIXES = {
    ".ets", ".ts", ".mjs", ".c", ".h", ".cpp", ".py",
    ".json5", ".yml", ".yaml", ".bat", ".sh", ".cmake", ".txt",
}
EXEMPT_NAMES = {"oh-package-lock.json5"}
EXEMPT_DIRS = {
    ".git", ".hvigor", ".third_party", "node_modules", "oh_modules",
    "build", ".cxx", ".build", "out",
}
EXEMPT_PATHS = {
    Path("entry/src/main/resources/rawfile/licenses/LICENSE-MPL-2.0.txt"),
    Path("entry/src/main/resources/rawfile/licenses/LICENSE-libssh2.txt"),
    Path("entry/src/main/resources/rawfile/licenses/LICENSE-mbedtls.txt"),
}

ROOT = Path(__file__).resolve().parent.parent


def iter_sources():
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in EXEMPT_DIRS for part in rel.parts):
            continue
        if path.name in EXEMPT_NAMES or rel in EXEMPT_PATHS:
            continue
        if path.suffix not in SUFFIXES:
            continue
        yield rel, path


def main() -> int:
    failures: list[str] = []
    for rel, path in iter_sources():
        head = path.read_text(encoding="utf-8", errors="replace")[:2000]
        if SPDX not in head:
            failures.append(f"{rel}: missing SPDX identifier")
        elif BOILERPLATE not in head:
            failures.append(f"{rel}: missing Exhibit A boilerplate")

    if failures:
        print("SPDX header check failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print("SPDX headers OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
