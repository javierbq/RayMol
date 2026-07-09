# RayMol native macOS/iOS app

This directory holds the native SwiftUI/Metal app (`PyMOLViewer.xcodeproj`) — a
separate build from the classic `pip install .` PyMOL Python package described
in the top-level `CLAUDE.md`. It embeds a standalone Python and a Metal-only
build of the PyMOL C++ core (`libpymol_core.a`) directly into a native app
bundle, rather than building a `_cmd` Python extension module.

There is currently no CI coverage for this build — it's local-only, built and
tested by hand.

## Building for macOS

1. **Install build-time dependencies.** These are headers/libraries needed
   only to compile `libpymol_core.a` and link the app — Python itself is
   vendored separately (next step), and OpenGL/GLEW/GLUT are never used (the
   app is Metal-only; see [Package-manager portability](#package-manager-portability)
   below for why that matters more than it sounds).

   Homebrew:
   ```bash
   brew install glm libpng freetype libomp
   ```
   MacPorts:
   ```bash
   sudo port install glm libpng freetype libomp
   ```

2. **Fetch the embedded Python.** One-time; re-run to refresh.
   ```bash
   scripts/fetch_macos_python.sh
   ```
   Downloads a `python-build-standalone` CPython 3.13 release into the
   gitignored `deps_macos/python-standalone/python`.

3. **Build the C++ core.**
   ```bash
   swiftui/build_macos.sh
   ```
   CMake-configures and builds `build_macos_swiftui/libpymol_core.a` — a
   Metal-only, `_PYMOL_NO_OPENGL` static library. MacPorts users: see below,
   you'll need an env var here too.

4. **Build the app in Xcode**, or via the command line:
   ```bash
   cd swiftui
   xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
       -configuration Debug -destination 'platform=macOS' build
   ```

## Package-manager portability

`swiftui/PyMOLBridge.xcconfig` (the Xcode-side build settings) and
`appkit/CMakeLists.txt` (the CMake core build) both default to Homebrew's
`/opt/homebrew` prefix for headers/libraries that aren't vendored in
`deps_macos/` — glm, libpng, freetype, libomp. This is controlled by a single
override point, `PYMOL_EXTERNAL_PREFIX`, rather than being hardcoded.

**If you're on Homebrew, you don't need to do anything** — the defaults
already point at `/opt/homebrew`.

**If you're on MacPorts** (or any other non-Homebrew prefix), two things need
the override, because Xcode and CMake read config independently:

1. For the CMake core build, set the env var when running `build_macos.sh`:
   ```bash
   PYMOL_EXTERNAL_PREFIX=/opt/local swiftui/build_macos.sh
   ```
2. For the Xcode app build, create a gitignored local override —
   `swiftui/PyMOLBridge.local.xcconfig` — since Xcode reads its own config
   independently of the shell env var above:
   ```
   PYMOL_EXTERNAL_PREFIX = /opt/local
   PYMOL_LIBOMP_STATIC = -L/opt/local/lib/libomp -lomp
   ```

That second line is the one non-obvious part, worth explaining rather than
just asserting: `PYMOL_LIBOMP_STATIC` can't be derived from
`PYMOL_EXTERNAL_PREFIX` alone, because Homebrew and MacPorts don't just put
`libomp` in different *locations* — they ship structurally different
*artifacts*. Homebrew ships a static `libomp.a` under a keg-style
`opt/libomp/lib`; MacPorts ships only a dynamic `libomp.dylib` under
`lib/libomp`, no static archive at all. There's no single path formula that
produces both shapes, so this has to be a full linker-flag override
(`-L<dir> -lomp`) rather than a bare path substitution. If you're on a
prefix that *does* ship a static `libomp.a` in a Homebrew-shaped layout, a
bare path like `/your/prefix/opt/libomp/lib/libomp.a` works fine too — the
variable accepts either form.

One more MacPorts-specific gotcha, unrelated to `PYMOL_EXTERNAL_PREFIX`:
`appkit/CMakeLists.txt` also locates a host Python3 interpreter to run the
shader-text generator at configure time. MacPorts installs versioned binaries
(`python3.13`, `python3.14`) with no generic `python3` in `/opt/local/bin`
unless you've run:
```bash
sudo port select --set python3 python313
```
Without that, CMake still finds a working `python3` by falling back to
`/usr/bin/python3` (Xcode Command Line Tools), so this isn't a hard
requirement — just worth knowing if you want the MacPorts interpreter used
instead of the system one.

Why GLEW/GLUT don't factor into any of this: `PyMOLBridge.xcconfig` defines
`_PYMOL_NO_OPENGL` for the macOS SDK (matching what the CMake core build
already does for this target), which compiles out the real-OpenGL branch of
`layer0/os_gl.h` — including its `GL/glew.h`/`GL/glut.h` includes — entirely.
Earlier revisions of this build lacked that macro on the Xcode side, which
silently pulled in the real-GL code path instead and required GLEW/GLUT to
even compile (invisibly papered over on Homebrew machines that happened to
have those headers installed already). They're not build-time dependencies
of this app.

## Building for iOS

The iOS app needs a gitignored `deps_ios/` populated with an embedded Python,
cross-compiled freetype/libpng, and numpy — the iOS analogue of `deps_macos/`.
Two scripts fetch/build the heavy pieces; the two after them layer Python
packages on top. Run them **in order** (each depends on the previous):

1. **Fetch the embedded Python.** One-time; re-run to refresh.
   ```bash
   scripts/fetch_ios_python.sh
   ```
   Downloads a [BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support)
   CPython 3.13 `Python.xcframework` (device + simulator slices) into
   `deps_ios/Python.xcframework`. The BeeWare release is **pinned** (`3.13-b12`)
   because b13+ moved the embedded stdlib to a `lib-<arch>/` layout the rest of
   the build doesn't expect — the script's layout guard rejects an incompatible
   release; see the header comment before overriding `PY_APPLE_SUPPORT_TAG`.

2. **Cross-compile freetype + libpng.**
   ```bash
   scripts/build_ios_deps.sh
   ```
   Builds libpng 1.6.44 + freetype 2.13.3 for arm64 into `deps_ios/install`
   (simulator SDK) and `deps_ios/install_device` (device SDK) — the
   `PYMOL_IOS_DEPS{,_DEVICE}` paths in `PyMOLBridge.xcconfig`. zlib comes from
   the iOS SDK. Needs Xcode + `cmake`.

3. **Cross-compile numpy.**
   ```bash
   scripts/build_numpy_ios.sh
   ```
   Stages numpy into `deps_ios/numpy-ios/{simulator,device}` (numpy ships no iOS
   wheels). Requires a host CPython 3.13 with `meson ninja cython` installed.

4. **Bundle Biopython** (optional; shared with the macOS app).
   ```bash
   scripts/bundle_biopython.sh
   ```
   Adds the pure-Python `Bio` subset into the xcframework's site-packages.

5. **Build the C++ core**, then the app:
   ```bash
   cd swiftui && ./build_ios.sh            # simulator (arm64)
   cd swiftui && ./build_ios.sh device     # device
   xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
       -configuration Debug -sdk iphonesimulator build
   ```

Everything under `deps_ios/` is gitignored and reproducible from steps 1–4;
delete the directory and re-run to rebuild from scratch.
