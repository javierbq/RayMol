# CMakeLists.txt - Build PyMOL as a native macOS AppKit application
#
# This is a standalone CMake project using appkit/ as the source directory.
# All PyMOL source files are referenced via PYMOL_ROOT (the parent directory).
#
# Usage:
#   mkdir build_appkit && cd build_appkit
#   cmake ../appkit -DCMAKE_BUILD_TYPE=Release
#   cmake --build . -j$(sysctl -n hw.ncpu)
#
# Xcode:
#   cmake -G Xcode ../appkit
#   cmake --build . --config Release

cmake_minimum_required(VERSION 3.20)

# Must be set BEFORE project() to take effect
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build for Apple Silicon only")
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "Minimum macOS version")

project(PyMOL LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# PyMOL source root (parent of this appkit/ directory)
get_filename_component(PYMOL_ROOT "${CMAKE_SOURCE_DIR}/.." ABSOLUTE)

# Options
option(PYMOL_LIBXML "Enable libxml2 (COLLADA)" ON)
option(PYMOL_VMD_PLUGINS "Enable VMD plugins" ON)
option(PYMOL_MSGPACKC "Enable msgpack-c" OFF)

# Dependency prefix — static libs built by scripts/build_deps.sh
set(DEPS_PREFIX "${PYMOL_ROOT}/deps/arm64" CACHE PATH "Static dependencies prefix")

# Embedded Python prefix — fetched by scripts/fetch_python.sh
set(PYMOL_PYTHON_PREFIX "${PYMOL_ROOT}/deps/python" CACHE PATH "Embedded Python prefix")

# Set up search paths for dependencies
if(EXISTS "${DEPS_PREFIX}")
    list(PREPEND CMAKE_PREFIX_PATH "${DEPS_PREFIX}")
endif()

# Fallback to Homebrew for development builds without static deps
if(EXISTS "/opt/homebrew" AND NOT EXISTS "${DEPS_PREFIX}/lib")
    message(STATUS "Static deps not found at ${DEPS_PREFIX}, falling back to Homebrew")
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew")
    link_directories("/opt/homebrew/lib")
endif()

# Find Python — prefer embedded python-build-standalone
if(EXISTS "${PYMOL_PYTHON_PREFIX}/bin/python3")
    set(Python3_ROOT_DIR "${PYMOL_PYTHON_PREFIX}")
    set(Python3_FIND_STRATEGY LOCATION)
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter Development NumPy)

# Detect Python version and pass as compile-time define
execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    OUTPUT_VARIABLE PYMOL_PYTHON_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
message(STATUS "Python version for embedding: ${PYMOL_PYTHON_VERSION}")

# Find system libraries
find_package(PNG REQUIRED)
find_package(Freetype REQUIRED)
find_library(GLEW_LIB GLEW REQUIRED HINTS "${DEPS_PREFIX}/lib")
find_path(GLEW_INCLUDE glew.h
    PATH_SUFFIXES GL GLEW
    HINTS "${DEPS_PREFIX}/include")
find_path(GLM_INCLUDE glm/glm.hpp
    HINTS "${DEPS_PREFIX}/include" "/opt/homebrew/include")

# Generate shader text and build info
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/generated)
execute_process(
    COMMAND ${Python3_EXECUTABLE} ${PYMOL_ROOT}/create_shadertext.py
        ${PYMOL_ROOT}/data/shaders
        ${PYMOL_ROOT}/data/shaders
        ${CMAKE_BINARY_DIR}/generated/ShaderText.h
        ${CMAKE_BINARY_DIR}/generated/ShaderText.cpp
    WORKING_DIRECTORY ${PYMOL_ROOT}
    RESULT_VARIABLE SHADER_RESULT
)
if(NOT SHADER_RESULT EQUAL 0)
    message(FATAL_ERROR "Shader text generation failed")
endif()

# Collect source files
file(GLOB_RECURSE PYMOL_SOURCES
    "${PYMOL_ROOT}/ov/src/*.cpp"  "${PYMOL_ROOT}/ov/src/*.c"
    "${PYMOL_ROOT}/layer0/*.cpp"  "${PYMOL_ROOT}/layer0/*.c"
    "${PYMOL_ROOT}/layer1/*.cpp"  "${PYMOL_ROOT}/layer1/*.c"
    "${PYMOL_ROOT}/layer2/*.cpp"  "${PYMOL_ROOT}/layer2/*.c"
    "${PYMOL_ROOT}/layer3/*.cpp"  "${PYMOL_ROOT}/layer3/*.c"
    "${PYMOL_ROOT}/layer4/*.cpp"  "${PYMOL_ROOT}/layer4/*.c"
    "${PYMOL_ROOT}/layerGraphics/*.cpp"
    "${PYMOL_ROOT}/layerGraphics/gl/*.cpp"
)

# AppKit entry point (Objective-C++)
set(APPKIT_SOURCES ${PYMOL_ROOT}/layer5/main_appkit.mm)

# Layer5 sources (exclude main.cpp — we use main_appkit.mm)
file(GLOB LAYER5_SOURCES "${PYMOL_ROOT}/layer5/*.cpp")
list(FILTER LAYER5_SOURCES EXCLUDE REGEX "main\\.cpp$")

# Generated sources
set(GENERATED_SOURCES
    ${CMAKE_BINARY_DIR}/generated/ShaderText.cpp
)

# VMD plugin sources
if(PYMOL_VMD_PLUGINS)
    file(GLOB VMD_SOURCES
        "${PYMOL_ROOT}/contrib/uiuc/plugins/molfile_plugin/src/*.c"
        "${PYMOL_ROOT}/contrib/uiuc/plugins/molfile_plugin/src/*.cpp"
    )
endif()

# All sources
set(ALL_SOURCES
    ${PYMOL_SOURCES}
    ${LAYER5_SOURCES}
    ${APPKIT_SOURCES}
    ${GENERATED_SOURCES}
    ${VMD_SOURCES}
)

# Create executable (macOS .app bundle)
add_executable(PyMOL MACOSX_BUNDLE ${ALL_SOURCES})

# Include directories
target_include_directories(PyMOL PRIVATE
    ${PYMOL_ROOT}/include
    ${PYMOL_ROOT}/ov/src
    ${PYMOL_ROOT}/layer0
    ${PYMOL_ROOT}/layer1
    ${PYMOL_ROOT}/layer2
    ${PYMOL_ROOT}/layer3
    ${PYMOL_ROOT}/layer4
    ${PYMOL_ROOT}/layer5
    ${PYMOL_ROOT}/layerGraphics
    ${PYMOL_ROOT}/layerGraphics/gl
    ${PYMOL_ROOT}/contrib/pocketfft
    ${CMAKE_BINARY_DIR}/generated
    ${Python3_INCLUDE_DIRS}
    ${Python3_NumPy_INCLUDE_DIRS}
    ${PNG_INCLUDE_DIRS}
    ${FREETYPE_INCLUDE_DIRS}
)

if(GLEW_INCLUDE)
    target_include_directories(PyMOL PRIVATE ${GLEW_INCLUDE})
endif()

if(PYMOL_VMD_PLUGINS)
    target_include_directories(PyMOL PRIVATE
        ${PYMOL_ROOT}/contrib/uiuc/plugins/include
        ${PYMOL_ROOT}/contrib/uiuc/plugins/molfile_plugin/src
    )
endif()

if(GLM_INCLUDE)
    target_include_directories(PyMOL PRIVATE ${GLM_INCLUDE})
endif()

# Preprocessor defines
target_compile_definitions(PyMOL PRIVATE
    _PYMOL_LIBPNG
    _PYMOL_FREETYPE
    _PYMOL_NUMPY
    _PYMOL_OSX
    _PYMOL_NO_MAIN
    _PYMOL_APPKIT
    _PYMOL_EMBEDDED
    PYMOL_CURVE_VALIDATE
    PYMOL_PYTHON_VERSION="${PYMOL_PYTHON_VERSION}"
)

if(PYMOL_VMD_PLUGINS)
    target_compile_definitions(PyMOL PRIVATE _PYMOL_VMD_PLUGINS)
endif()

if(PYMOL_LIBXML)
    find_library(XML2_LIB xml2 HINTS "${DEPS_PREFIX}/lib")
    find_path(XML2_INCLUDE libxml/parser.h
        PATH_SUFFIXES libxml2
        HINTS "${DEPS_PREFIX}/include")
    if(XML2_LIB AND XML2_INCLUDE)
        target_compile_definitions(PyMOL PRIVATE _HAVE_LIBXML)
        target_include_directories(PyMOL PRIVATE ${XML2_INCLUDE})
        target_link_libraries(PyMOL PRIVATE ${XML2_LIB})
        # Static libxml2 depends on iconv (system library on macOS)
        find_library(ICONV_LIB iconv)
        if(ICONV_LIB)
            target_link_libraries(PyMOL PRIVATE ${ICONV_LIB})
        endif()
    endif()
endif()

if(PYMOL_MSGPACKC)
    target_compile_definitions(PyMOL PRIVATE MMTF_MSGPACK_USE_CPP11 MSGPACK_NO_BOOST)
    target_include_directories(PyMOL PRIVATE ${PYMOL_ROOT}/contrib/mmtf-c)
else()
    target_compile_definitions(PyMOL PRIVATE _PYMOL_NO_MSGPACKC)
endif()

# Compiler flags
target_compile_options(PyMOL PRIVATE
    -Werror=return-type
    -Wno-switch
    -Wno-narrowing
    -Wno-char-subscripts
    -O2
    -fno-strict-aliasing
)

# Find optional netCDF (needed by VMD netcdf plugin)
find_library(NETCDF_LIB netcdf HINTS "${DEPS_PREFIX}/lib")
find_library(HDF5_LIB hdf5 HINTS "${DEPS_PREFIX}/lib")
find_library(HDF5_HL_LIB hdf5_hl HINTS "${DEPS_PREFIX}/lib")
find_library(ZLIB_LIB z HINTS "${DEPS_PREFIX}/lib")

# Link frameworks and libraries
target_link_libraries(PyMOL PRIVATE
    "-framework Cocoa"
    "-framework OpenGL"
    "-framework CoreVideo"
    ${Python3_LIBRARIES}
    ${PNG_LIBRARIES}
    ${FREETYPE_LIBRARIES}
    ${GLEW_LIB}
)
if(NETCDF_LIB)
    target_link_libraries(PyMOL PRIVATE ${NETCDF_LIB})
    # Static netcdf depends on HDF5 and zlib
    if(HDF5_HL_LIB)
        target_link_libraries(PyMOL PRIVATE ${HDF5_HL_LIB})
    endif()
    if(HDF5_LIB)
        target_link_libraries(PyMOL PRIVATE ${HDF5_LIB})
    endif()
endif()
# zlib — needed by libpng and others when statically linked
if(ZLIB_LIB)
    target_link_libraries(PyMOL PRIVATE ${ZLIB_LIB})
endif()

# macOS bundle properties
set_target_properties(PyMOL PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.pymol.PyMOL"
    MACOSX_BUNDLE_BUNDLE_NAME "PyMOL"
    MACOSX_BUNDLE_BUNDLE_VERSION "3.2.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "3.2.0"
    MACOSX_BUNDLE_INFO_PLIST "${PYMOL_ROOT}/cmake/Info.plist.in"
)

# Copy data files into the bundle
add_custom_command(TARGET PyMOL POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${PYMOL_ROOT}/data
        $<TARGET_BUNDLE_DIR:PyMOL>/Contents/Resources/data
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${PYMOL_ROOT}/modules
        $<TARGET_BUNDLE_DIR:PyMOL>/Contents/Resources/modules
)
