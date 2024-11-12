set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR x64)

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

if(ENV{DPREFIX})
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

set(ADDITIONAL_ARGS "-target x86_64-macos \
    -F ${TARGET_DARWIN_SDK_PATH} \
    -F /usr/libexec/darling/System/Library/Frameworks/ \
    -F /System/Library/Frameworks/ \
    -D'__OSX_AVAILABLE_BUT_DEPRECATED_MSG(_osxIntro, _osxDep, _iosIntro, _iosDep, _msg)='")

set(CMAKE_C_COMPILER "${ZIG}" CACHE FILEPATH "")
set(ENV{ZIG} "${ZIG}")
set(ENV{CC} "${CMAKE_C_COMPILER} cc ${ADDITIONAL_ARGS}")
set(CMAKE_CXX_COMPILER "${ZIG}" CACHE FILEPATH "")
set(ENV{CXX} "${CMAKE_CXX_COMPILER} c++ ${ADDITIONAL_ARGS}")

set(BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/../../build")

if(NOT ALREADY_HERE EQUAL 1)
    set(ALREADY_HERE 1)
    set(CMAKE_C_COMPILER_ARG1 "cc ${ADDITIONAL_ARGS} ${CMAKE_C_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_CXX_COMPILER_ARG1 "c++ ${ADDITIONAL_ARGS} ${CMAKE_CXX_COMPILER_ARG1}" CACHE STRING "")
    set(CMAKE_AR "${BUILD_DIR}/ar" CACHE FILEPATH "")
endif()

set(CMAKE_RC_COMPILER_INIT "${ZIG}")
set(CMAKE_RC_COMPILER_ARG1 "rc")
set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -- <SOURCE> <OBJECT>")
set(CMAKE_INSTALL_NAME_TOOL "${BUILD_DIR}/install_name_tool")
set(OPENGL_gl_LIBRARY /usr/libexec/darling/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib)
set(OPENGL_glu_LIBRARY /usr/libexec/darling/System/Library/Frameworks/OpenGL.framework/Libraries/libGLU.dylib)
set(OPENGL_INCLUDE_DIR ~/.darling/System/Library/Frameworks/OpenGL.framework/Versions/A/Headers/)
set(OPENGL_GLU_INCLUDE_DIR ~/.darling/System/Library/Frameworks/OpenGL.framework/Versions/A/Headers/)
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.8" CACHE STRING "" FORCE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PROGRAM_PATH "${BUILD_DIR}/vcpkg_installed/x64-windows-zig/")