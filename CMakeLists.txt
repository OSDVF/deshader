cmake_minimum_required(VERSION 3.19) # string(JSON) functions are required
project(deshader)

#
# Call Zig build system to compile Deshader
#
find_library(WOLFSSL wolfssl)

if(WOLFSSL AND NOT NO_SYSTEM_WOLFSSL)
    set(DESHADER_BUILD_FLAGS ${DESHADER_BUILD_FLAGS} -DwolfSSL)
    message(STATUS "Using system wolfssl")
endif()

if(CMAKE_BUILD_TYPE AND NOT DESHADER_BUILD_FLAGS MATCHES ".*\--release.*")
    if(CMAKE_BUILD_TYPE STREQUAL Release OR CMAKE_BUILD_TYPE STREQUAL RelWithDebInfo)
        set(DESHADER_BUILD_FLAGS ${DESHADER_BUILD_FLAGS} --release=safe)
    elseif(CMAKE_BUILD_TYPE STREQUAL MinSizeRel)
        set(DESHADER_BUILD_FLAGS ${DESHADER_BUILD_FLAGS} --release=small)
    endif()
endif()

if(VCPKG_TARGET_TRIPLET STREQUAL "x64-windows-cross" AND NOT DESHADER_BUILD_FLAGS MATCHES ".*\-Dtarget.*" AND NOT DESHADER_BUILD_FLAGS MATCHES ".*\-fwine.*")
    set(DESHADER_BUILD_FLAGS ${DESHADER_BUILD_FLAGS} -Dtarget=x64-windows-gnu -fwine)
endif()

file(
    GLOB
    ZIG_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/examples/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/src/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/src/declarations/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/src/interceptors/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/src/services/*.zig
    ${CMAKE_CURRENT_SOURCE_DIR}/src/tools/*.zig
)

separate_arguments(SEPARATED_DESHADER_FLAGS UNIX_COMMAND "${DESHADER_BUILD_FLAGS}")

set(DESHADER_OUTPUTS 
    lib/deshader.c
    lib/${CMAKE_SHARED_LIBRARY_PREFIX}deshader${CMAKE_SHARED_LIBRARY_SUFFIX}
    lib/${CMAKE_IMPORT_LIBRARY_PREFIX}deshader${CMAKE_IMPORT_LIBRARY_SUFFIX}
    include/deshader/deshader.hpp
    include/deshader/deshader.h
    include/deshader/deshader.zig
    include/deshader/deshader_prefixed.zig
    lib/deshader.ll
    lib/deshader.bc
)

add_custom_command(
    OUTPUT ${DESHADER_OUTPUTS}
    COMMAND zig build deshader ${SEPARATED_DESHADER_FLAGS} -p ${CMAKE_BINARY_DIR} -Dlib="${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib" # instruct zig to output into CMAKE_BINARY_DIR
    DEPENDS ${ZIG_SOURCES}
    BYPRODUCTS ${CMAKE_CURRENT_SOURCE_DIR}/zig-cache/
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMAND_EXPAND_LISTS
)

add_custom_target(
    deshader
    ALL
    DEPENDS ${DESHADER_OUTPUTS}
)
execute_process(
    COMMAND zig env
    TIMEOUT 5
    OUTPUT_VARIABLE ZIG_ENV
)
string(JSON ZIG_LIB_DIR GET ${ZIG_ENV} "lib_dir")

# Register Deshader library into cmake library system
add_library(
    deshader_zig
    SHARED IMPORTED
)
set_target_properties(deshader_zig PROPERTIES IMPORTED_LOCATION ${CMAKE_BINARY_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}deshader${CMAKE_SHARED_LIBRARY_SUFFIX})

if(WIN32)
    set_target_properties(deshader_zig PROPERTIES IMPORTED_IMPLIB ${CMAKE_BINARY_DIR}/lib/${CMAKE_IMPORT_LIBRARY_PREFIX}deshader${CMAKE_IMPORT_LIBRARY_SUFFIX})
endif()
add_dependencies(deshader_zig deshader)

#
# Compile examples written in C++
#
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD 99)
include_directories(${CMAKE_BINARY_DIR}/include/) # here is deshader.hpp

# Editor
add_executable(example_editor examples/editor_linked.cpp)

# Debug Commands
add_executable(example_debug_commands examples/debug_commands.cpp)
add_dependencies(example_debug_commands deshader)

# GLFW
add_executable(example_glfw examples/glfw.cpp)
find_package(glfw3 3.3)
find_package(GLEW)
target_link_libraries(example_glfw PUBLIC GLEW::GLEW glfw)
target_link_libraries(example_debug_commands PUBLIC GLEW::GLEW glfw)

# include binary resources https://copyprogramming.com/howto/embed-resources-eg-shader-code-images-into-executable-library-with-cmake
set(RC_DEPENDS "")

function(add_resource target directory input)
    set(output "${CMAKE_CURRENT_BINARY_DIR}/${input}.o")
    add_custom_command(
        OUTPUT ${output}
        COMMAND ${CMAKE_LINKER} --relocatable --format binary --output ${output} ${input}
        WORKING_DIRECTORY ${directory}
    )
    target_sources(${target} PRIVATE ${output})
    set(RC_DEPENDS ${RC_DEPENDS} ${output} PARENT_SCOPE)
endfunction()

if(WIN32)
	target_sources(example_glfw PRIVATE examples/shaders.rc)
else()
    add_resource(example_glfw "${CMAKE_CURRENT_SOURCE_DIR}/examples/" fragment.frag)
    add_resource(example_glfw "${CMAKE_CURRENT_SOURCE_DIR}/examples/" vertex.vert)
    add_custom_target(rc ALL DEPENDS ${RC_DEPENDS})
endif()

# Used for compiling Deshader C code
function(deshader_indirect_common_config)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(WEBKIT2GTK REQUIRED IMPORTED_TARGET webkit2gtk-4.0)
    pkg_check_modules(GTK+3 REQUIRED IMPORTED_TARGET gtk+-3.0)

    target_link_libraries(deshader_indirect PUBLIC PkgConfig::WEBKIT2GTK)
    target_link_libraries(deshader_indirect PUBLIC PkgConfig::GTK+3)

    if(WOLFSSL AND NOT NO_SYSTEM_WOLFSSL)
        target_link_libraries(deshader_indirect PUBLIC wolfssl)
    endif()
    set_target_properties(deshader_indirect PROPERTIES OUTPUT_NAME deshader)
endfunction(deshader_indirect_common_config)

string(REGEX MATCH ".*\-Dofmt=(.?.).*" _ ${DESHADER_BUILD_FLAGS} "") # -Dofmt= selects Zig output backend
set(DESHADER_OFMT ${CMAKE_MATCH_1})

if(DESHADER_OFMT STREQUAL c- OR DESHADER_OFMT STREQUAL "c ") # Use these commands to compile an application with deshader generated as C code
    message(STATUS "Using deshader as generated c code")
    set(REAL_ZIG_H ${ZIG_LIB_DIR}/zig.h)
    make_directory(${CMAKE_CURRENT_BINARY_DIR}/include)
    configure_file( # This also replaces ${REAL_ZIG_H} with real zig.h path
        ${CMAKE_CURRENT_SOURCE_DIR}/bootstrap/zig-fix.h
        ${CMAKE_CURRENT_BINARY_DIR}/include/zig.h
    )
    add_library(
        deshader_indirect
        SHARED
        ${CMAKE_CURRENT_SOURCE_DIR}/bootstrap/deshader-fix.c
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/positron/src/wv/webview.cpp
    )
    find_program(GCC_EXE "gcc")

    if(NOT ${GCC_EXE} STREQUAL GCC_EXE-NOTFOUND)
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.min.c
            COMMAND ${GCC_EXE} -fpreprocessed -dD -E ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.c > ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.min.c
            DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.c # To execute only after making Deshader
        )
    else()
        add_executable(
            strip_comments_exe
            ${CMAKE_CURRENT_SOURCE_DIR}/bootstrap/strip_comments.cpp
        )
        add_dependencies(strip_comments_exe deshader) # To execute only after making Deshader
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.min.c
            DEPENDS strip_comments_exe
            COMMAND ${CMAKE_CURRENT_BINARY_DIR}/strip_comments
            ARGS ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.c ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.min.c
        )
    endif()

    add_custom_target(
        strip_comments
        DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.min.c
    )

    # add_custom_command(
    # TARGET strip_comments
    # POST_BUILD
    # COMMAND ${CMAKE_COMMAND} -E rm ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.c
    # ) just for saving 50MBs of space :)
    add_dependencies(deshader_indirect strip_comments)
    set_target_properties(deshader_indirect PROPERTIES OUTPUT_NAME deshader) # because Deshader interception mechanism expets the library SONAME to be libdeshader.so
    target_include_directories(deshader_indirect PUBLIC ${CMAKE_CURRENT_BINARY_DIR}/lib)
    target_include_directories(deshader_indirect PUBLIC ${CMAKE_CURRENT_BINARY_DIR}/include)

    deshader_indirect_common_config()

    target_link_libraries(example_editor PUBLIC deshader_indirect)
elseif(DESHADER_OFMT STREQUAL IR)
    message(STATUS "Using deshader as generated IR")
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/deshader.ll.o
        COMMAND llc
        ARGS -filetype=obj --relocation-model=pic ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.ll -o ${CMAKE_CURRENT_BINARY_DIR}/deshader.ll.o
        DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.ll
    )
    add_library(
        deshader_indirect
        SHARED
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/positron/src/wv/webview.cpp
    )
    add_custom_target(
        deshader_ll
        DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/deshader.ll.o
    )
    add_dependencies(deshader_indirect deshader_ll)
    target_link_libraries(deshader_indirect PUBLIC ${CMAKE_CURRENT_BINARY_DIR}/deshader.ll.o)

    deshader_indirect_common_config()
    target_link_libraries(example_editor PUBLIC deshader_indirect)
elseif(DESHADER_OFMT STREQUAL BC)
    message(STATUS "Using deshader as generated BC")
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/deshader.bc.o
        COMMAND llc
        ARGS -filetype=obj --relocation-model=pic ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.bc -o ${CMAKE_CURRENT_BINARY_DIR}/deshader.bc.o
        DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/lib/deshader.bc
    )
    add_library(
        deshader_indirect
        SHARED
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/positron/src/wv/webview.cpp
    )
    add_custom_target(
        deshader_bc
        DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/deshader.bc.o
    )
    add_dependencies(deshader_indirect deshader_bc)
    target_link_libraries(deshader_indirect PUBLIC ${CMAKE_CURRENT_BINARY_DIR}/deshader.bc.o)

    deshader_indirect_common_config()
    target_link_libraries(example_editor PUBLIC deshader_indirect)
else()
    message(STATUS "Using deshader compiled by Zig")
    target_link_libraries(example_editor PUBLIC deshader_zig)
endif()
