set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x64)
set(VCPKG_POLICY_DLLS_WITHOUT_LIBS enabled) # Ignores cmake warning `warning: Import libraries were not present in` because import `.lib`s are generated as `libX.dll.a` instead of `X.lib`

find_program(ZIG_PATH zig)
get_filename_component(ZIG_DIR ${ZIG_PATH} DIRECTORY)

set(tools ${ZIG_DIR})
set(CMAKE_C_COMPILER ${tools}/zig CACHE FILEPATH "")
set(ENV{ZIG} "${tools}/zig")
set(ENV{CC} "${CMAKE_C_COMPILER} cc -target x86_64-windows")
set(CMAKE_CXX_COMPILER ${tools}/zig CACHE FILEPATH "")
set(ENV{CXX} "${CMAKE_CXX_COMPILER} c++ -target x86_64-windows")

set(BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/../../build")

if(NOT ALREADY_HERE EQUAL 1)
    set(ALREADY_HERE 1)
    set(CMAKE_C_COMPILER_ARG1 "cc -target x86_64-windows ${CMAKE_C_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_CXX_COMPILER_ARG1 "c++ -target x86_64-windows ${CMAKE_CXX_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_AR "${BUILD_DIR}/ar" CACHE FILEPATH "")
endif()

set(CMAKE_RC_COMPILER_INIT ${tools}/zig)
set(CMAKE_RC_COMPILER_ARG1 "rc")
set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -- <SOURCE> <OBJECT>")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PROGRAM_PATH "${BUILD_DIR}/vcpkg_installed/x64-windows-cross/")

message(STATUS "UUU Toolchain loaded")