@echo off
rem Copyright (C) 2026 MC4HOS Contributors
rem SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
rem
rem This Source Code Form is subject to the terms of the Mozilla Public
rem License, v. 2.0. If a copy of the MPL was not distributed with this
rem file, You can obtain one at https://mozilla.org/MPL/2.0/.

rem Builds an unsigned HAP with the local DevEco Studio installation.
rem The native core downloads mbedTLS and libssh2 at configure time, pinned
rem by SHA-256. Set OHTERM_OFFLINE=1 to reuse a populated .third_party dir.
rem
rem Override the install location with:  set DEVECO_STUDIO_HOME=<dir>
setlocal

set "ROOT=%~dp0.."

if not defined DEVECO_STUDIO_HOME set "DEVECO_STUDIO_HOME=C:\Program Files\Huawei\DevEco Studio"
if not exist "%DEVECO_STUDIO_HOME%\tools\hvigor\bin\hvigorw.js" (
  echo ERROR: DevEco Studio not found at "%DEVECO_STUDIO_HOME%"
  echo        Set DEVECO_STUDIO_HOME to your install directory and retry.
  exit /b 1
)
echo Toolchain: %DEVECO_STUDIO_HOME%

set "NODE=%DEVECO_STUDIO_HOME%\tools\node\node.exe"
set "HVIGORW_JS=%DEVECO_STUDIO_HOME%\tools\hvigor\bin\hvigorw.js"
set "DEVECO_SDK_HOME=%DEVECO_STUDIO_HOME%\sdk"

if exist "%DEVECO_STUDIO_HOME%\tools\ohpm\bin\ohpm.bat" (
  echo Running ohpm install...
  call "%DEVECO_STUDIO_HOME%\tools\ohpm\bin\ohpm.bat" install
  if errorlevel 1 (
    echo ERROR: ohpm install failed
    exit /b 1
  )
) else (
  echo [warn] ohpm not found under tools\ohpm - skipping dependency install
)

cd /d "%ROOT%"
echo Building HAP ^(debug, unsigned^)...
call "%NODE%" "%HVIGORW_JS%" --mode module -p module=entry@default -p product=default assembleHap
if errorlevel 1 (
  echo ERROR: hvigor build failed - see output above
  exit /b 1
)

if not exist out mkdir out
for /r "%ROOT%\entry\build" %%f in (*.hap) do copy /y "%%f" "out\" >nul
echo.
echo Done. HAP file(s):
dir /b "%ROOT%\out\*.hap"
echo Location: %ROOT%\out
endlocal
