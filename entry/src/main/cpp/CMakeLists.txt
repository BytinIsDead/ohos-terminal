# Terminal core: NAPI bridge over libssh2 + mbedTLS.
#
# Copyright (C) 2026 MC4HOS Contributors
# SPDX-License-Identifier: MPL-2.0-no-copyleft-exception
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# libssh2 and mbedTLS are fetched from their release archives at configure
# time (pinned by SHA-256), cross-compiled with the OHOS NDK toolchain for
# both arm64-v8a and x86_64, and linked statically into libterminal_core.so.
# Neither project is committed here; their license texts are bundled in the
# HAP under resources/rawfile/licenses/. Set OHTERM_OFFLINE=1 to use a
# pre-populated .third_party directory instead of downloading.

cmake_minimum_required(VERSION 3.9.0)
project(terminal_core C CXX)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

message(STATUS "terminal_core - target ABI: ${OHOS_ARCH}")

include(FetchContent)
set(FETCHCONTENT_BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.third_party"
    CACHE PATH "Third-party sources fetched at configure time")
set(FETCHCONTENT_UPDATES_DISCONNECTED ON)

# mbedTLS 3.6.2 (Apache-2.0). Release tarball includes the framework
# submodule; tests and programs are disabled.
if(NOT OHTERM_OFFLINE)
  FetchContent_Declare(mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2
    URL_HASH SHA256=8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
endif()
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(GEN_FILES OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(mbedtls)

# libssh2 1.11.1 (BSD-3-Clause), mbedTLS backend.
if(NOT OHTERM_OFFLINE)
  FetchContent_Declare(libssh2
    URL https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz
    URL_HASH SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
endif()
set(CRYPTO_BACKEND "mbedTLS" CACHE STRING "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_ZLIB_COMPRESSION OFF CACHE BOOL "" FORCE)
set(LINT OFF CACHE BOOL "" FORCE)
set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE PATH "" FORCE)
# libssh2's install(EXPORT) cannot reference a build-tree target from another
# project, so point its FindMbedTLS at the archive path instead of the
# mbedcrypto target (file paths are exportable).
set(MBEDCRYPTO_LIBRARY
    "${mbedtls_BINARY_DIR}/library/${CMAKE_STATIC_LIBRARY_PREFIX}mbedcrypto${CMAKE_STATIC_LIBRARY_SUFFIX}"
    CACHE FILEPATH "" FORCE)
FetchContent_MakeAvailable(libssh2)

add_library(terminal_core SHARED
        napi_init.cpp
        src/ssh_bridge.c)

target_compile_definitions(terminal_core PRIVATE OHTERM_USE_MBEDTLS)
target_include_directories(terminal_core PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${mbedtls_SOURCE_DIR}/include")

find_library(napi-lib ace_napi.z)
find_library(dl-lib dl)

target_link_libraries(terminal_core PRIVATE
        ${napi-lib}
        ${dl-lib}
        libssh2
        mbedtls
        mbedcrypto)
