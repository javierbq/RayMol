# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PyMOL is a molecular visualization system. The codebase is a hybrid C++17/Python project using a layered architecture with Python bindings via a custom `_cmd` extension module.

## Build Commands

```bash
# Clean build
pip install .

# Developer build (verbose, incremental, with C++ tests)
pip install --verbose --no-build-isolation --config-settings testing=True .

# Debug build
DEBUG=1 pip install --verbose --no-build-isolation --config-settings testing=True .

# With dev dependencies (biopython, msgpack, pillow, PySide6, pytest)
pip install --verbose --no-build-isolation --config-settings testing=True '.[dev]'
```

Build config settings: `--glut=true`, `--libxml=no`, `--use-msgpackc=no`, `--testing=True`, `--openvr=true`, `--vmd-plugins=no`.

Environment variables: `PREFIX_PATH`, `CXX`, `CC`, `CXXFLAGS`, `CFLAGS`, `CPPFLAGS`, `LDFLAGS`.

## Testing

Tests use `unittest` via a custom runner that must be invoked through PyMOL:

```bash
# Run all tests
pymol -ckqy testing/testing.py --run all

# Run a specific test file
pymol -ckqy testing/testing.py --run tests/api/callback.py
```

Tests live in `testing/tests/` organized by category (`api/`, `cgos/`, `properties/`, `settings/`, `system/`, `undo/`, `jira/`, `wizard/`, `performance/`). Test cases subclass `pymol.testing.PyMOLTestCase` and use methods named `test*`.

Key test utilities: `@testing.requires()`, `@testing.foreach()`, `assertImageEqual()`, `assertImageHasColor()`, `assertArrayEqual()`, `timing()`, `mktemp()`.

## Code Formatting

C++ uses `.clang-format` (Linux brace style, 2-space indent, 80-column limit). No Python formatter is configured.

## Development Workflow

- **Git flow:** Do not commit or push directly to `master`. Create a feature branch, push it, and open a pull request into `master` for review before merging.
- **macOS app testing:** When functionally testing the native macOS SwiftUI/Metal app, use the `mac-vm-test` skill whenever it is available. It builds on the host and drives the app inside an isolated, disposable macOS VM (leased from the `javierbq/mac-vm-pool` golden image) rather than touching the host's own UI.

## Architecture

### C++ Layer System

The C++ code is organized in numbered layers of increasing abstraction:

- **layer0**: Core utilities — memory management, math, I/O, data structures, string handling
- **layer1**: Object model — molecular structures (`ObjectMolecule`), maps, scene management, settings system
- **layer2**: Representations and rendering — molecular representations (cartoon, surface, sticks, etc.), geometry, atom/bond operations
- **layer3**: High-level operations — selectors, iterators, executive commands
- **layer4**: Command interface — command parsing and dispatch
- **layer5**: Main entry point
- **layerGraphics**: OpenGL rendering pipeline
- **layerCTest**: C++ unit tests (catch2)

### Python Modules (in `modules/`)

- **pymol/**: Main Python API. Functionality split by domain: `importing.py`, `editing.py`, `selecting.py`, `viewing.py`, `exporting.py`, `creating.py`, `fitting.py`, etc. The `_cmd` C extension is the bridge to C++ layers.
- **chempy/**: Chemistry utilities and data structures
- **pmg_qt/**: PyQt/PySide GUI implementation
- **pmg_tk/**: Legacy Tk GUI
- **pymol2/**: PyMOL 2.x Python API

### Other Key Directories

- **contrib/**: Third-party code (CHAMP, mmtf-c, pocketfft, UIUC VMD plugins, VR support)
- **data/shaders/**: GLSL shaders (.vs, .fs, .gs) — compiled at build time by `create_shadertext.py` into `ShaderText.h/.cpp`
- **include/**: C/C++ headers (public API in `include/pymol/`)

### Build Pipeline

The build uses a custom PEP 517 backend (`_custom_build/backend.py`) wrapping setuptools. `setup.py` defines `CMakeExtension` and `build_ext_pymol` which invoke CMake. Shaders are auto-generated before compilation via `create_shadertext.py`.

## Requirements

- C++17 compiler (gcc 8+)
- CMake 3.13+
- Python 3.9+ (CI tests 3.10–3.13)
- OpenGL, GLEW, GLM, libpng, freetype
- Optional: libxml2, msgpack-c, mmtf-cpp, catch2, libnetcdf, PyQt5/6/PySide2/6
