<img src="./swiftui/PyMOLViewer/Resources/RayMol.svg" height="100" align="right" />

# RayMol

[![Join Slack](https://img.shields.io/badge/Slack-Join_Community-4A154B?logo=slack&logoColor=white)](https://raymol.slack.com/archives/C0BE58D4E7P)

**RayMol** is a native **macOS · iPad · iPhone** reimagining of the [PyMOL](https://pymol.org) molecular visualization system. Built with SwiftUI and Metal, it pairs a modern touch- and pointer-native user interface with the real PyMOL C++ chemistry and graphics core and an embedded CPython 3.13 runtime, running the full `pymol` Python API on-device. RayMol is an open-source fork of [pymol-open-source](https://github.com/schrodinger/pymol-open-source).

## Highlights

- **Metal renderer & hardware ray tracing** — Real-time ray-cast spheres and cylinders, smooth spline cartoons, order-independent transparency, and hardware-accelerated ambient occlusion and shadows on Apple Silicon (`metal_raytrace`, on by default where supported).
- **Studio lights & atmosphere** (beta, not yet released) — Up to six spot lights per scene with customizable beam widths, warmth, and colored shadows, plus volumetric haze and floating dust drift (`lights` and `atmosphere`).
- **Materials & Looks** — Per-object materials (matte, plastic, metallic, glass, frosted glass, jelly, marble, clay, rubber) with realistic refraction and reflections, plus one-click Looks (gold, copper, statuary marble, terracotta).
- **Camera lens & depth of field** — True focal length and dolly-zoom camera controls (wide-angle to telephoto) and scatter-based bokeh depth of field with autofocus on active selections.
- **Timeline movie studio** — Docked multi-track timeline editor for animating camera keyframes, scene cuts, and multi-state (NMR/MD) ensemble playback.
- **Structure prediction** — On-device structure prediction with Boltz-2 (all platforms) and Protenix (AlphaFold3-class, macOS only) via **Tools ▸ Enter Predict Mode** (`⌃P`) or `cmd.predict`, with remote MSA search and live progress reporting. Prediction on iPad and iPhone requires iOS/iPadOS 18.
- **Sequence design** — On-device ProteinMPNN sequence design in Design mode via **Tools ▸ Enter Design Mode** (`⌃D`) with live rescoring and sidechain repacking, plus experimental, macOS-only RFdiffusion3 backbone generation (`binder_design`; generates a backbone, not a confirmed binder). Design mode on iPad and iPhone requires iOS/iPadOS 18.
- **Metrics** — Per-residue and whole-structure prediction and design confidence scores (pLDDT, PAE, certainty, native fit) attached directly to molecular objects (`metrics_get`, `metrics_color`).
- **Analysis notes** — In-session Markdown notes with tags, camera/scene view links, and live scientific inserts (selected residues, contacts around selection, measurements).
- **Glycobiology** (next release) — SNFG-compliant (Symbol Nomenclature for Glycans) 3D cartoon symbols and color conventions for carbohydrate residues (`glycocartoon`, `glycocolor`).
- **Grid mode** — Side-by-side multi-structure comparison in customizable grid cells with independent picking, clipping, and shadows (`set grid_mode, 1`).
- **Built-in MCP server for AI apps** — Local Model Context Protocol server enabling Claude Code and the Claude desktop app to inspect and drive RayMol (macOS only; excluded from the Mac App Store build).
- **Theme Studio** — Live-preview theming system with presets (Classic, Paper, Sunset, Dawn) and custom palette configuration for application chrome and molecular defaults.

## Documentation

User documentation is available online at **[https://javierbq.github.io/RayMol/](https://javierbq.github.io/RayMol/)**, which is what **Documentation** on [raymol.io](https://raymol.io) links to.

**The Markdown files in [`docs/src/content/docs/`](docs/src/content/docs/) are the source of that site:** what you read under raymol.io ▸ **Documentation** is these pages, built with Astro Starlight and deployed automatically to GitHub Pages by [`.github/workflows/deploy-docs.yml`](.github/workflows/deploy-docs.yml) whenever a release is published or a `v*` tag is pushed (or on manual dispatch). To update or add user documentation, edit those files and update the sidebar navigation in `docs/astro.config.mjs`; see the [Documentation Contributor Guide](docs/README.md) for instructions.

Detailed per-version release notes are available in [`docs/release-notes/`](docs/release-notes/).

## Install

### macOS

- **Homebrew:**
  ```sh
  brew install --cask javierbq/raymol/raymol
  ```
- **Notarized DMG:** Download the latest notarized disk image from [GitHub Releases](https://github.com/javierbq/RayMol/releases/latest). The standalone DMG includes automatic in-app updates via Sparkle.
- **Mac App Store:** Install from the [App Store](https://apps.apple.com/us/app/raymol/id6781513038).

### iPad & iPhone

- Install directly from the [App Store](https://apps.apple.com/us/app/raymol/id6781513038).

### System Requirements

- **macOS:** 14.0 (Sonoma) or newer. Requires an Apple Silicon Mac (M-series); hardware ray tracing and on-device ML models require Apple Silicon.
- **iOS / iPadOS:** 17.0 or newer.

## Building from Source

### Native App (macOS & iOS)

The native app lives in [`swiftui/`](swiftui/) and embeds both standalone CPython and a Metal-only build of the PyMOL C++ core (`libpymol_core.a`).

To build the macOS app locally:

1. Install build dependencies via Homebrew:
   ```sh
   brew install glm libpng freetype libomp
   ```
2. Fetch the embedded standalone CPython 3.13:
   ```sh
   scripts/fetch_macos_python.sh
   ```
3. Compile the C++ core:
   ```sh
   swiftui/build_macos.sh
   ```
4. Build the app in Xcode using `swiftui/PyMOLViewer.xcodeproj` (scheme `PyMOLViewer_macOS`), or run:
   ```sh
   cd swiftui
   xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -destination 'platform=macOS' build
   ```

For iOS build instructions and troubleshooting, see [`swiftui/README.md`](swiftui/README.md).

### Classic PyMOL Core & Python Module

To build the traditional Python package and `_cmd` extension module:

```sh
pip install --verbose --no-build-isolation --config-settings testing=True .
```

Run the unit test suite with:

```sh
pymol -ckqy testing/testing.py --run all
```

See [INSTALL](INSTALL) and [CLAUDE.md](CLAUDE.md) for build options and development guidelines.

## Repository Layout

| Path | Purpose |
|---|---|
| [`swiftui/`](swiftui) | Native macOS, iPadOS, and iOS app (SwiftUI, Metal, PyMOLBridge) |
| `layer0`–`layer5` | PyMOL C++ core layers (math, object models, representations, selectors, commands) |
| `layerGraphics` | Graphics abstraction layer and Metal / OpenGL rendering engines |
| [`modules/pymol`](modules/pymol) | Python API, RayMol extension commands, predictors, and generators |
| [`data/shaders`](data/shaders) | GLSL shader source files (Metal shaders live in `layerGraphics/metal/`) |
| [`docs/`](docs) | Documentation site (Astro Starlight), release notes, and technical design documents |
| [`testing/`](testing) | Python unit tests and custom test runner |

## Contributing

We welcome contributions! Please review [DEVELOPERS](DEVELOPERS) for coding style and project conventions.

RayMol uses a standard feature branch workflow:
1. Fork or branch from `master`.
2. Create a feature branch for your changes.
3. Open a pull request against `master` for review before merging. Direct commits to `master` are not permitted.

## Community & Support

- **Slack:** Join the [RayMol Community Slack](https://raymol.slack.com/archives/C0BE58D4E7P) for discussions, announcements, and troubleshooting.
- **Support:** Reach out via [support@raymol.io](mailto:support@raymol.io) or visit [https://raymol.io/support](https://raymol.io/support).
- **Issues:** Report bugs or request features on [GitHub Issues](https://github.com/javierbq/RayMol/issues).

## Credits & License

RayMol is built on **PyMOL**, Copyright (c) [Schrödinger, LLC](https://www.schrodinger.com/), and is published under the same BSD-like license — see [LICENSE](LICENSE). PyMOL is a trademark of Schrödinger, LLC; RayMol is an independent fork and is not affiliated with or endorsed by Schrödinger.
