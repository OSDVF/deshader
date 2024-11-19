set(VCPKG_TARGET_ARCHITECTURE $ENV{ZIG_ARCH})
set(VCPKG_CMAKE_SYSTEM_NAME $ENV{ZIG_OS})
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_ENV_PASSTHROUGH PATH;ZIG_PATH;ZIG_TARGET)
set(VCPKG_KEEP_ENV_VARS PATH;ZIG_PATH;ZIG_TARGET)

set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE ${CMAKE_CURRENT_LIST_DIR}/../toolchain/zig.cmake)
include(${VCPKG_CHAINLOAD_TOOLCHAIN_FILE})


