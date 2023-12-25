set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME Windows)
set(VCPKG_TARGET_IS_WINDOWS ON)
set(VCPKG_TARGET_IS_MINGW ON)

message(STATUS "UUU Triplet loaded")

set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE ${CMAKE_CURRENT_LIST_DIR}/../toolchain/x64-windows-cross.cmake)
include(${VCPKG_CHAINLOAD_TOOLCHAIN_FILE})