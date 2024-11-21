set(VCPKG_POLICY_DLLS_WITHOUT_LIBS enabled) # Ignores cmake warning `warning: Import libraries were not present in` because import `.lib`s are generated as `libX.dll.a` instead of `X.lib`

if(NOT DEFINED $ENV{ZIG_PATH})
    find_program(ZIG_PATH "zig${CMAKE_EXECUTABLE_SUFFIX}")
else()
    set(ZIG_PATH $ENV{ZIG_PATH})
endif()
get_filename_component(ZIG_DIR ${ZIG_PATH} DIRECTORY)


if(NOT ZIG_PATH)
    set(ZIG "zig")
else()
    set(ZIG ${ZIG_PATH})
endif()

if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    if(DEFINED ENV{DPREFIX})
        set(DARLING_PREFIX $ENV{DPREFIX})
    else()
        set(DARLING_PREFIX "~/.darling")
    endif()

    if(CMAKE_HOST_SYSTEM MATCHES "Darwin")
        execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE DARWIN_SDK_PATH OUTPUT_STRIP_TRAILING_WHITESPACE)
        set(TARGET_DARWIN_SDK_PATH ${DARWIN_SDK_PATH})
    else()
        execute_process(COMMAND darling shell xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE DARWIN_SDK_PATH OUTPUT_STRIP_TRAILING_WHITESPACE)
        set(TARGET_DARWIN_SDK_PATH "${DARLING_PREFIX}/${DARWIN_SDK_PATH}")
    endif()

    if (EXISTS /usr/libexec/darling)
        set(DARLING_SYSTEM_PREFIX /usr/libexec/darling)
    else()
        set(DARLING_SYSTEM_PREFIX /usr/local/libexec/darling)
    endif()

    set(ADDITIONAL_ARGS "-target $ENV{ZIG_TARGET}"
        "-F ${TARGET_DARWIN_SDK_PATH}/System/Library/Frameworks"
        "-L ${TARGET_DARWIN_SDK_PATH}/usr/lib"
        "-F ${TARGET_DARWIN_SDK_PATH}/System/Library/PrivateFrameworks"
        "-F ${DARLING_SYSTEM_PREFIX}/System/Library/Frameworks"
        "-F /System/Library/Frameworks"
        "-mmacosx-version-min=10.16"
        "-ObjC"
        "-fobjc-runtime=macosx"
        "-framework AppKit"
        "-D'__OSX_AVAILABLE_STARTING(_osx, _ios)='"
        "-D' __OSX_AVAILABLE_BUT_DEPRECATED(_osxIntro, _osxDep, _iosIntro, _iosDep)='"
        "-D'__OSX_AVAILABLE_BUT_DEPRECATED_MSG(_osxIntro, _osxDep, _iosIntro, _iosDep, _msg)='") # Zig does not somehow parse availability macros correctly

    
    if(DEFINED ENV{MACOSSDK})
        list(APPEND ADDITIONAL_ARGS "-F $ENV{MACOSSDK}/System/Library/Frameworks")
        list(APPEND ADDITIONAL_ARGS "-F $ENV{MACOSSDK}/System/Library/PrivateFrameworks")
        list(APPEND ADDITIONAL_ARGS "-F $ENV{MACOSSDK}/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks")
        list(APPEND ADDITIONAL_ARGS "-F $ENV{MACOSSDK}/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks")
    endif()

    set(CMAKE_INSTALL_NAME_TOOL "${BUILD_DIR}/install_name_tool")
    set(OPENGL_gl_LIBRARY ${DARLING_SYSTEM_PREFIX}/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib)
    set(OPENGL_glu_LIBRARY ${DARLING_SYSTEM_PREFIX}/System/Library/Frameworks/OpenGL.framework/Libraries/libGLU.dylib)
    set(OPENGL_INCLUDE_DIR ${DARLING_PREFIX}/System/Library/Frameworks/OpenGL.framework/Versions/A/Headers/)
    set(OPENGL_GLU_INCLUDE_DIR ${DARLING_PREFIX}/System/Library/Frameworks/OpenGL.framework/Versions/A/Headers/)

else()
    set(ADDITIONAL_ARGS "-target $ENV{ZIG_TARGET}")
endif()
    
string (REPLACE ";" " " ADDITIONAL_ARGS_STR "${ADDITIONAL_ARGS}")

set(CMAKE_C_COMPILER "${ZIG}" CACHE FILEPATH "")
set(ENV{ZIG} "${ZIG}")
set(ENV{CC} "${CMAKE_C_COMPILER} cc ${ADDITIONAL_ARGS_STR}")
set(CMAKE_CXX_COMPILER "${ZIG}" CACHE FILEPATH "")
set(ENV{CXX} "${CMAKE_CXX_COMPILER} c++ ${ADDITIONAL_ARGS_STR}")

set(BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/../../build")

if(NOT ALREADY_HERE EQUAL 1)
    set(ALREADY_HERE 1)
    set(CMAKE_C_COMPILER_ARG1 "cc ${ADDITIONAL_ARGS_STR} ${CMAKE_C_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_CXX_COMPILER_ARG1 "c++ ${ADDITIONAL_ARGS_STR} ${CMAKE_CXX_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_AR "${BUILD_DIR}/ar" CACHE FILEPATH "")
endif()

set(CMAKE_RC_COMPILER_INIT "${ZIG}")
set(CMAKE_RC_COMPILER_ARG1 "rc")
set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -- <SOURCE> <OBJECT>")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_PROGRAM_PATH "${BUILD_DIR}/vcpkg_installed/${VCPKG_TARGET_TRIPLET}/")