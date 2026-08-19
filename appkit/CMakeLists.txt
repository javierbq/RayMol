# CMakeLists.txt - Build PyMOL as a native macOS/iOS application
#
# macOS (AppKit executable + static lib):
#   mkdir build_appkit && cd build_appkit
#   cmake ../appkit -DCMAKE_BUILD_TYPE=Release
#   cmake --build . -j$(sysctl -n hw.ncpu)
#
# iOS Simulator (static lib only):
#   mkdir build_ios && cd build_ios
#   cmake ../appkit -DCMAKE_TOOLCHAIN_FILE=../appkit/ios.toolchain.cmake \
#         -DIOS_PLATFORM=SIMULATOR64 -C ../appkit/CMakeLists_iOS.cmake
#   cmake --build . --target pymol_core -j$(sysctl -n hw.ncpu)
#
# iOS Device (static lib only):
#   mkdir build_ios_device && cd build_ios_device
#   cmake ../appkit -DCMAKE_TOOLCHAIN_FILE=../appkit/ios.toolchain.cmake \
#         -DIOS_PLATFORM=OS -C ../appkit/CMakeLists_iOS.cmake
#   cmake --build . --target pymol_core -j$(sysctl -n hw.ncpu)

cmake_minimum_required(VERSION 3.20)
project(PyMOL LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# PyMOL source root (parent of this appkit/ directory)
get_filename_component(PYMOL_ROOT "${CMAKE_SOURCE_DIR}/.." ABSOLUTE)

# Detect iOS cross-compilation
option(PYMOL_IOS "Building for iOS (Metal only, no OpenGL)" OFF)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(PYMOL_IOS ON)
endif()

# Native macOS Metal-only build for the SwiftUI app: no OpenGL/GLEW; embedded
# python-build-standalone (headers via PYMOL_PYTHON_INCLUDE_DIR) instead of
# Homebrew Python. Builds only pymol_core (no AppKit executable).
option(PYMOL_METAL_ONLY "Native macOS Metal-only build (no OpenGL)" OFF)

# External package-manager prefix for build-time headers/libs not vendored in
# deps_macos/deps_ios (freetype, libpng, glm, GLEW). Homebrew by default;
# override with -DPYMOL_EXTERNAL_PREFIX=/opt/local for MacPorts.
set(PYMOL_EXTERNAL_PREFIX "/opt/homebrew" CACHE PATH "External package-manager prefix (Homebrew/MacPorts)")

# Options
option(PYMOL_LIBXML "Enable libxml2 (COLLADA)" ON)
option(PYMOL_VMD_PLUGINS "Enable VMD plugins" ON)
option(PYMOL_MSGPACKC "Enable msgpack-c" OFF)

# --- Platform-specific dependency discovery ---

if(PYMOL_METAL_ONLY)
    # Native macOS, Metal-only (no OpenGL), embedded standalone Python. The
    # static lib only needs headers; linking happens in the Xcode app via
    # PyMOLBridge.xcconfig. Python headers come from the staged
    # python-build-standalone tree (PYMOL_PYTHON_INCLUDE_DIR); png/freetype
    # headers from Homebrew (build-time only).
    set(BREW_PREFIX "${PYMOL_EXTERNAL_PREFIX}")
    set(Python3_INCLUDE_DIRS "${PYMOL_PYTHON_INCLUDE_DIR}")
    set(Python3_NumPy_INCLUDE_DIRS "")
    set(PNG_INCLUDE_DIRS "${BREW_PREFIX}/include/libpng16" "${BREW_PREFIX}/include")
    set(FREETYPE_INCLUDE_DIRS "${BREW_PREFIX}/include/freetype2" "${BREW_PREFIX}/include")
    find_path(GLM_INCLUDE glm/glm.hpp HINTS ${BREW_PREFIX}/include)
    message(STATUS "macOS metal-only build: standalone Python headers ${Python3_INCLUDE_DIRS}")
elseif(NOT PYMOL_IOS)
    # macOS: use Homebrew and system packages
    if(EXISTS "/opt/homebrew")
        list(PREPEND CMAKE_PREFIX_PATH "/opt/homebrew")
        link_directories("/opt/homebrew/lib")
    endif()

    find_package(Python3 REQUIRED COMPONENTS Interpreter Development NumPy)
    find_package(PNG REQUIRED)
    find_package(Freetype REQUIRED)
    find_library(GLEW_LIB GLEW REQUIRED HINTS /opt/homebrew/lib)
    find_path(GLEW_INCLUDE glew.h
        PATH_SUFFIXES GL GLEW
        HINTS /opt/homebrew/include)
    find_path(GLM_INCLUDE glm/glm.hpp
        HINTS /opt/homebrew/include)
else()
    # iOS: headers-only mode for static library compilation.
    # Use BeeWare Python.xcframework headers for iOS builds;
    # actual linking happens in the Xcode project.
    set(BREW_PREFIX "${PYMOL_EXTERNAL_PREFIX}")
    set(PYMOL_IOS_DEPS "${CMAKE_SOURCE_DIR}/../deps_ios" CACHE PATH "iOS dependencies root")

    # Python headers from BeeWare Python.xcframework (3.13)
    set(PYTHON_XCFW "${PYMOL_IOS_DEPS}/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework")
    if(EXISTS "${PYTHON_XCFW}/Headers/Python.h")
        set(Python3_INCLUDE_DIRS "${PYTHON_XCFW}/Headers")
    else()
        # Fallback to Homebrew headers
        set(PYTHON_VERSION "3.13" CACHE STRING "Python version for headers")
        set(Python3_INCLUDE_DIRS "${BREW_PREFIX}/opt/python@${PYTHON_VERSION}/Frameworks/Python.framework/Versions/${PYTHON_VERSION}/include/python${PYTHON_VERSION}")
    endif()
    set(Python3_NumPy_INCLUDE_DIRS "") # NumPy headers optional for iOS
    set(PNG_INCLUDE_DIRS "${BREW_PREFIX}/include/libpng16" "${BREW_PREFIX}/include")
    set(FREETYPE_INCLUDE_DIRS "${BREW_PREFIX}/include/freetype2" "${BREW_PREFIX}/include")

    find_path(GLM_INCLUDE glm/glm.hpp
        HINTS ${BREW_PREFIX}/include)

    message(STATUS "iOS build: using Homebrew headers for cross-compilation")
    message(STATUS "  Python headers: ${Python3_INCLUDE_DIRS}")
    message(STATUS "  PNG headers: ${PNG_INCLUDE_DIRS}")
    message(STATUS "  Freetype headers: ${FREETYPE_INCLUDE_DIRS}")
endif()

# Generate shader text (uses host Python, works for both platforms)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/generated)

# For iOS / metal-only, find the host Python to run the shader generator
if(PYMOL_IOS OR PYMOL_METAL_ONLY)
    find_program(HOST_PYTHON python3 HINTS /opt/homebrew/bin ${PYMOL_EXTERNAL_PREFIX}/bin /usr/bin)
else()
    set(HOST_PYTHON ${Python3_EXECUTABLE})
endif()

execute_process(
    COMMAND ${HOST_PYTHON} ${PYMOL_ROOT}/create_shadertext.py
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

# Collect source files (use GLOB for layerGraphics to avoid recursing into gl/)
file(GLOB_RECURSE PYMOL_SOURCES
    "${PYMOL_ROOT}/ov/src/*.cpp"  "${PYMOL_ROOT}/ov/src/*.c"
    "${PYMOL_ROOT}/layer0/*.cpp"  "${PYMOL_ROOT}/layer0/*.c"
    "${PYMOL_ROOT}/layer1/*.cpp"  "${PYMOL_ROOT}/layer1/*.c"
    "${PYMOL_ROOT}/layer2/*.cpp"  "${PYMOL_ROOT}/layer2/*.c"
    "${PYMOL_ROOT}/layer3/*.cpp"  "${PYMOL_ROOT}/layer3/*.c"
    "${PYMOL_ROOT}/layer4/*.cpp"  "${PYMOL_ROOT}/layer4/*.c"
)
file(GLOB LAYERGFX_SOURCES "${PYMOL_ROOT}/layerGraphics/*.cpp")
list(APPEND PYMOL_SOURCES ${LAYERGFX_SOURCES})

# Include GL sources only for the OpenGL (AppKit) macOS build; iOS and the
# native Metal-only macOS build use GL stubs instead.
if(NOT PYMOL_IOS AND NOT PYMOL_METAL_ONLY)
    file(GLOB GL_SOURCES "${PYMOL_ROOT}/layerGraphics/gl/*.cpp")
    list(APPEND PYMOL_SOURCES ${GL_SOURCES})
else()
    list(APPEND PYMOL_SOURCES "${PYMOL_ROOT}/layerGraphics/gl/GLVertexBuffer_stubs.cpp")
endif()

# Layer5 sources (exclude main.cpp and main_appkit.mm — platform-specific entry points)
file(GLOB LAYER5_SOURCES "${PYMOL_ROOT}/layer5/*.cpp")
list(FILTER LAYER5_SOURCES EXCLUDE REGEX "main\\.cpp$")
list(FILTER LAYER5_SOURCES EXCLUDE REGEX "main_appkit")

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
    # netcdfplugin needs an external libnetcdf that isn't built for the
    # Metal/iOS targets; drop it (its init is also guarded out in
    # PlugIOManagerInit.c). Everything else (DCD/XTC/TRR/CCP4/MRC/DX/…) is
    # dependency-free or uses the SDK's zlib.
    list(FILTER VMD_SOURCES EXCLUDE REGEX "netcdfplugin")
endif()

# Core library sources (everything except the AppKit entry point)
set(CORE_SOURCES
    ${PYMOL_SOURCES}
    ${LAYER5_SOURCES}
    ${GENERATED_SOURCES}
    ${VMD_SOURCES}
    ${PYMOL_ROOT}/layerGraphics/metal/RendererMetal.mm
)

# Static library for use by SwiftUI project (and potentially other frontends)
add_library(pymol_core STATIC ${CORE_SOURCES})

# CHAMP (chempy.champ._champ): chemistry / charge-assignment native module used
# by vacuum electrostatics, fix_chemistry, etc. Built as an OBJECT library with
# its OWN include dir (contrib/champ ships os_python.h / vla.h / os_std.h that
# must NOT shadow the core's same-named headers) and folded into the core static
# lib so the SwiftUI app — which already links pymol_core — gets PyInit__champ.
# The bridge registers it via PyImport_AppendInittab("_champ", PyInit__champ).
file(GLOB CHAMP_OBJ_SOURCES "${PYMOL_ROOT}/contrib/champ/*.c")
add_library(champ_obj OBJECT ${CHAMP_OBJ_SOURCES})
target_include_directories(champ_obj PRIVATE
    ${PYMOL_ROOT}/contrib/champ
    ${Python3_INCLUDE_DIRS})
target_sources(pymol_core PRIVATE $<TARGET_OBJECTS:champ_obj>)

# Shared include directories
set(PYMOL_INCLUDE_DIRS
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
    ${PYMOL_ROOT}/layerGraphics/metal
    ${PYMOL_ROOT}/contrib/pocketfft
    ${CMAKE_BINARY_DIR}/generated
    ${Python3_INCLUDE_DIRS}
    ${PNG_INCLUDE_DIRS}
    ${FREETYPE_INCLUDE_DIRS}
)
if(Python3_NumPy_INCLUDE_DIRS)
    list(APPEND PYMOL_INCLUDE_DIRS ${Python3_NumPy_INCLUDE_DIRS})
endif()

target_include_directories(pymol_core PRIVATE ${PYMOL_INCLUDE_DIRS})

# Shared preprocessor defines
set(PYMOL_DEFINES
    _PYMOL_LIBPNG
    _PYMOL_FREETYPE
    _PYMOL_OSX
    _PYMOL_NO_MAIN
    _PYMOL_EMBEDDED
    _PYMOL_NO_MSGPACKC
    PYMOL_CURVE_VALIDATE
)

if(PYMOL_IOS)
    list(APPEND PYMOL_DEFINES _PYMOL_NO_OPENGL _PYMOL_IOS)
elseif(PYMOL_METAL_ONLY)
    list(APPEND PYMOL_DEFINES _PYMOL_NO_OPENGL _PYMOL_METAL_ONLY)
else()
    list(APPEND PYMOL_DEFINES _PYMOL_NUMPY _PYMOL_APPKIT)
endif()

target_compile_definitions(pymol_core PRIVATE ${PYMOL_DEFINES})

# Shared compiler flags
set(PYMOL_COMPILE_FLAGS
    -Werror=return-type -Wno-switch -Wno-narrowing
    -Wno-char-subscripts -O2 -fno-strict-aliasing
)
target_compile_options(pymol_core PRIVATE ${PYMOL_COMPILE_FLAGS})

# OpenMP — parallel solvent-dot surface sampling (layer2/RepSurface.cpp). On by
# default for the desktop Metal build (NOT iOS). Apple clang needs libomp
# (Homebrew, keg-only) + -Xpreprocessor -fopenmp for omp.h/pragmas. pymol_core is
# a STATIC archive, so the OpenMP runtime symbols stay unresolved here and are
# pulled in by the final app link (libomp.a, linked statically in project.yml).
option(PYMOL_OPENMP "Parallelize surface sampling with OpenMP" ON)
if(PYMOL_OPENMP AND NOT PYMOL_IOS)
    find_path(LIBOMP_INCLUDE omp.h
        HINTS /opt/homebrew/opt/libomp/include /usr/local/opt/libomp/include
              ${PYMOL_EXTERNAL_PREFIX}/include/libomp ${PYMOL_EXTERNAL_PREFIX}/opt/libomp/include)
    if(LIBOMP_INCLUDE)
        target_compile_definitions(pymol_core PRIVATE PYMOL_OPENMP)
        target_compile_options(pymol_core PRIVATE -Xpreprocessor -fopenmp)
        target_include_directories(pymol_core PRIVATE ${LIBOMP_INCLUDE})
        message(STATUS "PyMOL OpenMP enabled (libomp headers: ${LIBOMP_INCLUDE})")
    else()
        message(WARNING "PYMOL_OPENMP requested but omp.h not found — building serial surface path")
    endif()
endif()

if(NOT PYMOL_IOS AND GLEW_INCLUDE)
    target_include_directories(pymol_core PRIVATE ${GLEW_INCLUDE})
endif()

if(PYMOL_VMD_PLUGINS)
    # netcdf plugin is excluded from the build (needs external libnetcdf);
    # guard out its init/register/fini in PlugIOManagerInit.c.
    target_compile_definitions(pymol_core PRIVATE _PYMOL_VMD_PLUGINS PYMOL_NO_NETCDF_PLUGIN)
    target_include_directories(pymol_core PRIVATE
        ${PYMOL_ROOT}/contrib/uiuc/plugins/include
        ${PYMOL_ROOT}/contrib/uiuc/plugins/molfile_plugin/src
    )
endif()

if(GLM_INCLUDE)
    target_include_directories(pymol_core PRIVATE ${GLM_INCLUDE})
endif()

if(PYMOL_LIBXML AND NOT PYMOL_IOS)
    find_library(XML2_LIB xml2 HINTS /opt/homebrew/lib ${PYMOL_EXTERNAL_PREFIX}/lib)
    find_path(XML2_INCLUDE libxml/parser.h
        PATH_SUFFIXES libxml2
        HINTS /opt/homebrew/include ${PYMOL_EXTERNAL_PREFIX}/include)
    if(XML2_LIB AND XML2_INCLUDE)
        target_compile_definitions(pymol_core PRIVATE _HAVE_LIBXML)
        target_include_directories(pymol_core PRIVATE ${XML2_INCLUDE})
    endif()
endif()

if(PYMOL_MSGPACKC)
    target_compile_definitions(pymol_core PRIVATE MMTF_MSGPACK_USE_CPP11 MSGPACK_NO_BOOST)
    target_include_directories(pymol_core PRIVATE ${PYMOL_ROOT}/contrib/mmtf-c)
endif()

# ============================================================
# macOS-only targets (executable, _champ module, bundle setup)
# ============================================================
if(NOT PYMOL_IOS AND NOT PYMOL_METAL_ONLY)
    # All sources for the AppKit executable
    set(ALL_SOURCES
        ${CORE_SOURCES}
        ${PYMOL_ROOT}/layer5/main_appkit.mm
    )

    add_executable(PyMOL MACOSX_BUNDLE ${ALL_SOURCES})

    target_include_directories(PyMOL PRIVATE ${PYMOL_INCLUDE_DIRS})

    if(GLEW_INCLUDE)
        target_include_directories(PyMOL PRIVATE ${GLEW_INCLUDE})
    endif()

    if(PYMOL_VMD_PLUGINS)
        target_include_directories(PyMOL PRIVATE
            ${PYMOL_ROOT}/contrib/uiuc/plugins/include
            ${PYMOL_ROOT}/contrib/uiuc/plugins/molfile_plugin/src
        )
        target_compile_definitions(PyMOL PRIVATE _PYMOL_VMD_PLUGINS)
    endif()

    if(GLM_INCLUDE)
        target_include_directories(PyMOL PRIVATE ${GLM_INCLUDE})
    endif()

    target_compile_definitions(PyMOL PRIVATE
        _PYMOL_LIBPNG _PYMOL_FREETYPE _PYMOL_NUMPY _PYMOL_OSX
        _PYMOL_NO_MAIN _PYMOL_APPKIT _PYMOL_EMBEDDED
        PYMOL_CURVE_VALIDATE
    )

    if(PYMOL_LIBXML AND XML2_LIB AND XML2_INCLUDE)
        target_compile_definitions(PyMOL PRIVATE _HAVE_LIBXML)
        target_include_directories(PyMOL PRIVATE ${XML2_INCLUDE})
        target_link_libraries(PyMOL PRIVATE ${XML2_LIB})
    endif()

    if(PYMOL_MSGPACKC)
        target_compile_definitions(PyMOL PRIVATE MMTF_MSGPACK_USE_CPP11 MSGPACK_NO_BOOST)
        target_include_directories(PyMOL PRIVATE ${PYMOL_ROOT}/contrib/mmtf-c)
    else()
        target_compile_definitions(PyMOL PRIVATE _PYMOL_NO_MSGPACKC)
    endif()

    target_compile_options(PyMOL PRIVATE ${PYMOL_COMPILE_FLAGS})

    find_library(NETCDF_LIB netcdf HINTS /opt/homebrew/lib)

    target_link_libraries(PyMOL PRIVATE
        "-framework Cocoa"
        "-framework OpenGL"
        "-framework CoreVideo"
        "-framework Metal"
        "-framework MetalKit"
        ${Python3_LIBRARIES}
        ${PNG_LIBRARIES}
        ${FREETYPE_LIBRARIES}
        ${GLEW_LIB}
    )
    if(NETCDF_LIB)
        target_link_libraries(PyMOL PRIVATE ${NETCDF_LIB})
    endif()

    set_target_properties(PyMOL PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER "org.pymol.PyMOL"
        MACOSX_BUNDLE_BUNDLE_NAME "PyMOL"
        MACOSX_BUNDLE_BUNDLE_VERSION "3.2.0"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "3.2.0"
        MACOSX_BUNDLE_INFO_PLIST "${PYMOL_ROOT}/cmake/Info.plist.in"
    )

    # _champ Python extension module
    file(GLOB CHAMP_SOURCES "${PYMOL_ROOT}/contrib/champ/*.c")
    add_library(_champ MODULE ${CHAMP_SOURCES})
    target_include_directories(_champ PRIVATE
        ${PYMOL_ROOT}/contrib/champ
        ${Python3_INCLUDE_DIRS}
    )
    target_link_libraries(_champ PRIVATE ${Python3_LIBRARIES})
    set_target_properties(_champ PROPERTIES
        PREFIX "" SUFFIX ".so" OUTPUT_NAME "_champ"
    )

    add_custom_command(TARGET _champ POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
            $<TARGET_FILE:_champ>
            $<TARGET_BUNDLE_DIR:PyMOL>/Contents/Resources/modules/chempy/champ/_champ.so
    )

    add_custom_command(TARGET PyMOL POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${PYMOL_ROOT}/data
            $<TARGET_BUNDLE_DIR:PyMOL>/Contents/Resources/data
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${PYMOL_ROOT}/modules
            $<TARGET_BUNDLE_DIR:PyMOL>/Contents/Resources/modules
    )
endif()
