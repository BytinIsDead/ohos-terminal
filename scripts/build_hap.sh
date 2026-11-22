#!/usr/bin/env bash
# Copyright (C) 2026 MC4HOS Contributors
# SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds an unsigned HAP with a local DevEco Studio install or the
# standalone commandline-tools package. Windows users: build_hap.bat.
#
# The native core downloads mbedTLS and libssh2 at configure time, pinned by
# SHA-256. Set OHTERM_OFFLINE=1 to reuse a populated .third_party directory.
#
# Override the toolchain location with DEVECO_STUDIO_HOME.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Accept DevEco Studio (tools/...), command-line-tools (hvigor/..., tool/node)
# and hyphenated command-line-tools checkouts.
find_hvigor() {
  local base="$1"
  for candidate in \
    "$base/tools/hvigor/bin/hvigorw.js" \
    "$base/hvigor/bin/hvigorw.js"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TOOLS_HOME="${DEVECO_STUDIO_HOME:-}"
if [ -z "$TOOLS_HOME" ]; then
  for candidate in \
    "/Applications/DevEco-Studio.app/Contents" \
    "$HOME/commandline-tools" \
    "$HOME/hos-tools/commandline-tools" \
    "$HOME/hos-tools/command-line-tools" \
    "/opt/harmonyos/commandline-tools"; do
    if find_hvigor "$candidate" >/dev/null; then
      TOOLS_HOME="$candidate"
      break
    fi
  done
fi

if [ -z "$TOOLS_HOME" ] || ! HVIGORW_JS="$(find_hvigor "$TOOLS_HOME")"; then
  echo "ERROR: DevEco Studio / commandline-tools not found."
  echo "       Set DEVECO_STUDIO_HOME to the install directory and retry."
  exit 1
fi
echo "Toolchain: $TOOLS_HOME"

NODE_BIN="$TOOLS_HOME/tool/node/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$TOOLS_HOME/tools/node/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$(command -v node)"
export DEVECO_SDK_HOME="$TOOLS_HOME/sdk"

OHPM="$TOOLS_HOME/tools/ohpm/bin/ohpm"
[ -x "$OHPM" ] || OHPM="$TOOLS_HOME/ohpm/bin/ohpm"
if [ -x "$OHPM" ]; then
  echo "Running ohpm install..."
  "$OHPM" install
elif [ -d "$ROOT/oh_modules" ]; then
  echo "[warn] ohpm not found - using existing oh_modules"
else
  echo "ERROR: ohpm not found and no oh_modules present"
  exit 1
fi

cd "$ROOT"
echo "Building HAP (debug, unsigned)..."
"$NODE_BIN" "$HVIGORW_JS" --mode module -p module=entry@default -p product=default assembleHap

mkdir -p out
find entry/build -name "*.hap" -exec cp {} out/ \;
echo
echo "Done. HAP file(s):"
ls -la out/*.hap
