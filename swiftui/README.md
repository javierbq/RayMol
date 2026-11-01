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

   **Stale-core guard.** The Xcode project links whatever `libpymol_core.a`
   already exists, so a pre-build phase (`scripts/check_core_fresh.sh`) fails
   the build with `libpymol_core.a is stale: run swiftui/build_macos.sh` when
   the C++ sources (`layer*/`, `ov/`, `contrib/`, `include/`, `appkit/`,
   shaders) differ from what the core was built from. `build_macos.sh` /
   `build_ios.sh` write that fingerprint and the core's git SHA to
   `core_sha.txt` next to the library; the SHA also appears in the console
   banner (`core 1fc5fc983`). It compares file *contents*, so Swift-only
   edits, `touch` and fresh git worktrees do not trip it. Bypass it with
   `RAYMOL_SKIP_CORE_CHECK=1` (env var, or `xcodebuild ... RAYMOL_SKIP_CORE_CHECK=1`).
   A core built before stamping existed only warns until it is rebuilt.

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
instead of the system one. `scripts/build_numpy_ios.sh` has the identical
fallback (`PYMOL_EXTERNAL_PREFIX/bin/python3.13` → nothing) and needs the
selected interpreter to actually have `meson`/`ninja`/`cython` installed —
see [Building for iOS](#building-for-ios) below.

Why GLEW/GLUT don't factor into any of this: `PyMOLBridge.xcconfig` defines
`_PYMOL_NO_OPENGL` for the macOS SDK (matching what the CMake core build
already does for this target), which compiles out the real-OpenGL branch of
`layer0/os_gl.h` — including its `GL/glew.h`/`GL/glut.h` includes — entirely.
Earlier revisions of this build lacked that macro on the Xcode side, which
silently pulled in the real-GL code path instead and required GLEW/GLUT to
even compile (invisibly papered over on Homebrew machines that happened to
have those headers installed already). They're not build-time dependencies
of this app.

The iOS `PYMOL_IOS` CMake branch and `scripts/build_numpy_ios.sh`'s `PYHOST`
default both honor `PYMOL_EXTERNAL_PREFIX` the same way — MacPorts users pass
it the same way as the macOS build, see below.

## Building for iOS

The iOS app needs a gitignored `deps_ios/` populated with an embedded Python,
cross-compiled freetype/libpng, numpy, and (optionally) Biopython — the iOS
analogue of `deps_macos/`. Unlike the macOS side's single Python download,
this is a real cross-compiled dependency set with more moving pieces, so
there's a wrapper that runs all of them in the right order:

```bash
scripts/setup_ios_deps.sh
# MacPorts: PYMOL_EXTERNAL_PREFIX=/opt/local scripts/setup_ios_deps.sh
```

That's the one-command equivalent of the macOS side's `fetch_macos_python.sh`
— re-run it to refresh everything; each step underneath is independently
idempotent. What it runs, in order (useful to know for troubleshooting, or to
re-run just one step):

1. **`scripts/fetch_ios_python.sh`** — downloads a
   [BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support)
   CPython 3.13 `Python.xcframework` (device + simulator slices) into
   `deps_ios/Python.xcframework`. The BeeWare release is **pinned** (`3.13-b12`)
   because b13+ moved the embedded stdlib to a `lib-<arch>/` layout the rest of
   the build doesn't expect — the script's layout guard rejects an incompatible
   release; see the header comment before overriding `PY_APPLE_SUPPORT_TAG`.

2. **`scripts/build_ios_deps.sh`** — cross-compiles libpng 1.6.44 + freetype
   2.13.3 for arm64 into `deps_ios/install` (simulator SDK) and
   `deps_ios/install_device` (device SDK) — the `PYMOL_IOS_DEPS{,_DEVICE}`
   paths in `PyMOLBridge.xcconfig`. zlib comes from the iOS SDK. Needs Xcode +
   `cmake`.

3. **`scripts/build_numpy_ios.sh`** — stages numpy into
   `deps_ios/numpy-ios/{simulator,device}` (numpy ships no iOS wheels).
   Requires a host CPython 3.13 with `meson`, `ninja`, and `cython` installed
   **and resolvable on `PATH`** (`pip install --user meson ninja cython`
   installs its console scripts to a user-site `bin/` directory that usually
   isn't on `PATH` by default — pip will warn you about this at install time;
   add that directory to `PATH` or the numpy meson build won't find `cython`).

4. **`scripts/bundle_biopython.sh`** (optional; shared with the macOS app) —
   adds the pure-Python `Bio` subset into the xcframework's site-packages.

Everything under `deps_ios/` is gitignored and reproducible from these four
steps; delete the directory and re-run `setup_ios_deps.sh` to rebuild from
scratch.

### Building for the iOS Simulator

This is the fast path — as simple as the macOS build, no Apple Developer
account needed at all:

```bash
cd swiftui && ./build_ios.sh              # builds libpymol_core.a for the simulator
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
    -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

The simulator build self-signs ("Sign to Run Locally") automatically —
nothing below applies. To install and launch it once built:

```bash
APP=~/Library/Developer/Xcode/DerivedData/PyMOLViewer-*/Build/Products/Debug-iphonesimulator/RayMol.app
xcrun simctl boot "<simulator UDID>"        # if not already booted
xcrun simctl install "<simulator UDID>" "$APP"
xcrun simctl launch "<simulator UDID>" io.raymol.RayMol
```

### Building for a physical iPad/iPhone

This is where the iOS and macOS paths genuinely diverge, and it's not a gap
in this build system — it's Apple's platform policy: any code you run on
real iOS hardware must be signed with a registered Apple Developer identity,
full stop. There's no equivalent hurdle on macOS ("Sign to Run Locally"
works for a local Debug build there). If this is the **first time** this
Mac + this device have been used for iOS development, expect a real,
one-time setup dance before the build itself will succeed:

1. **Enable Developer Mode on the device.** Settings → Privacy & Security →
   Developer Mode → toggle on → the device restarts → confirm "Turn On"
   after restart. Without this, `xcodebuild`/`devicectl` report the device as
   `connected (no DDI)` and refuse to install anything.
2. **Add your Apple ID to Xcode.** Xcode → Settings → Accounts → **+**. If
   your account belongs to multiple teams (e.g. a personal free team and a
   paid organization team), you'll choose which one signs the build — a free
   personal team works for local testing but expires certificates every 7
   days; a paid team doesn't.
3. **Accept a pending Program License Agreement**, if the build fails with
   `PLA Update available: You currently don't have access to this membership
   resource.` Sign in at [developer.apple.com/account](https://developer.apple.com/account)
   with the team's credentials and accept the agreement banner. Only an
   Admin/Agent-role account on the team can usually do this.
4. **Register the device**, if the build fails with `Device "<name>" isn't
   registered in your developer account.` Try Xcode → Window → Devices and
   Simulators → select the device → "Use for Development" first (often
   auto-registers); otherwise an Admin/Agent on the team must add its UDID
   manually at [developer.apple.com/account/resources/devices/add](https://developer.apple.com/account/resources/devices/add)
   (`xcrun devicectl device info details --device <device-id>` prints the UDID).

Once all of that's done (it's one-time per Mac+device+team combination), the
actual build/install/launch:

```bash
cd swiftui && ./build_ios.sh device       # builds libpymol_core.a for device

xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -configuration Debug \
    -destination 'id=<device-id>' -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=<TEAMID> CODE_SIGN_STYLE=Automatic build

APP=~/Library/Developer/Xcode/DerivedData/PyMOLViewer-*/Build/Products/Debug-iphoneos/RayMol.app
xcrun devicectl device install app --device <device-id> "$APP"
xcrun devicectl device process launch --device <device-id> io.raymol.RayMol
```

`xcrun devicectl list devices` shows connected devices and their `<device-id>`.
`DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE` are passed on the command line rather
than committed to `project.pbxproj`, since the right team ID is
developer/organization-specific, not a shared project setting.
