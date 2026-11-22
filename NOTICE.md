# NOTICE

OHOS Terminal — Copyright (C) 2026 MC4HOS Contributors.

Licensed under the Mozilla Public License, version 2.0, with the Exhibit B
"no copyleft exception" form. SPDX-License-Identifier:
`MPL-2.0-no-copyleft-exception`.

Every source file carries the Exhibit A notice:

```
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
```

The full MPL 2.0 text is in `LICENSE` and is packaged in the HAP at
`resources/rawfile/licenses/LICENSE-MPL-2.0.txt`.

## Third-party components

OHOS Terminal statically links the following libraries into
`libterminal_core.so`. No third-party source is copied into this repository;
the build fetches pinned release archives by URL with SHA-256 verification.

### libssh2 1.11.1

- Upstream: https://libssh2.org/
- Source archive: https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz
- SHA-256: `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`
- License: BSD 3-Clause
- License text: `entry/src/main/resources/rawfile/licenses/LICENSE-libssh2.txt`

```
Copyright (c) 2004-2007 Sara Golemon <sarag@libssh2.org>
Copyright (c) 2005,2006 Mikhail Gusarov <dottedmag@dottedmag.net>
Copyright (c) 2006-2007 The Written Word, Inc.
Copyright (c) 2007 Eli Fant <elifantu@mail.ru>
Copyright (c) 2009-2014 Daniel Stenberg
Copyright (C) 2008, 2009 Simon Josefsson
All rights reserved.
```

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

### mbedTLS 3.6.2

- Upstream: https://www.trustedfirmware.org/projects/mbed-tls/
- Source archive: https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2
- SHA-256: `8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca`
- License: Apache License 2.0
- License text: `entry/src/main/resources/rawfile/licenses/LICENSE-mbedtls.txt`

```
Copyright The Mbed TLS Contributors
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Assets

The application icon is part of this repository and is covered by the MPL
2.0 Exhibit B license. No Minecraft, Mojang, Microsoft or other proprietary
assets or code are included.
