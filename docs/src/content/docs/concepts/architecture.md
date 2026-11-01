---
title: Engine & System Architecture
description: How RayMol combines PyMOL's C++ core, embedded CPython 3.13, a native Metal renderer, MLX inference, and the Model Context Protocol.
---

RayMol brings the open-source PyMOL molecular visualization engine to modern Apple platforms (macOS, iPadOS, and iOS). Rather than running a legacy OpenGL desktop port inside an emulation layer or wrapper, RayMol pairs PyMOL's battle-tested C++ calculation engine with a native SwiftUI interface, an embedded CPython 3.13 runtime, a high-performance Apple Metal rendering engine, and on-device machine learning inference.

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        SwiftUI Application Layer                       │
│     (Windows, Inspector, Command Line, Native Touch/Gestures)          │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
          Objective-C++ Bridge                Embedded CPython 3.13
                                              (from pymol import cmd)
                    │                                │
┌───────────────────▼────────────────────────────────▼───────────────────┐
│                           PyMOL C++ Engine                             │
│     (layer0: Utilities  •  layer1: Scene    •  layer2: Molecules      │
│      layer3: Executive  •  layer4: Python/C •  layer5: Coordination)   │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
           ┌─────────────────────────┼─────────────────────────┐
           ▼                         ▼                         ▼
   Metal Render Pipeline      On-Device ML (MLX)       Local MCP Server
   • Analytic Impostors      • Boltz-2 / Protenix      • Loopback JSON-RPC
   • Spline Cartoons         • RFdiffusion3 (macOS)    • Bearer-token authed
   • WBOIT Transparency      • ProteinMPNN             • Direct tool driving
   • Hardware Ray Tracing    • Memory Arbitration      • macOS desktop direct
   • Studio HDR Light Rigs
```

## The PyMOL C++ layers

At its core, RayMol preserves the molecular data structures, selection syntax, symmetry operations, and file parsers of PyMOL. The C++ codebase is structured into layered tiers of abstraction:

- **layer0 (Core utilities):** Low-level memory management, 3D math and vector operations, file and network I/O, error handling, and string formatting.
- **layer1 (Scene, settings, colour):** scene management and camera, the global and per-object setting system (`Setting`, `SettingInfo`), colours, crystal symmetry, CGO geometry and the CPU ray tracer.
- **layer2 (Molecules & representations):** molecular data models (`ObjectMolecule`), coordinate sets, volumetric maps, and the generation of cartoons, sticks, spheres, surfaces and meshes.
- **layer3 (Executive operations):** High-level atom selections, property filtering, structural alignments, fitting, and state management.
- **layer4 (Python/C boundary):** the `_cmd` extension module that exposes the engine to Python, plus the legacy menu code. Command-line parsing and keyword dispatch live in the Python layer (`modules/pymol/parser.py`, `keywords.py`).
- **layer5 (Engine coordination):** Central application lifecycle and PyMOL instance state orchestration (`CPyMOL`).

RayMol keeps PyMOL's renderer abstraction (`layerGraphics`) but swaps the OpenGL backend (`layerGraphics/gl`) for a Metal one (`layerGraphics/metal/RendererMetal`), which the scene layer drives directly.

## The Objective-C++ bridge

Communication between the modern Swift/SwiftUI interface and the C++ engine flows through an Objective-C++ bridge.

The bridge provides a clean C/C++ boundary that:
- Initializes and tears down PyMOL instances.
- Coordinates the main render loop with Apple display refresh rates (ProMotion up to 120 Hz).
- Translates native pointer, mouse, trackpad, and multi-touch gestures into PyMOL button and drag events.
- Synchronizes UI theme settings, selection colors, and hover-preview highlights.
- Handles offscreen high-resolution image rendering.
- Dispatches keyboard shortcuts to PyMOL's key bindings (`cmd.set_key`).

## Embedded CPython 3.13

RayMol embeds a full, native CPython 3.13 interpreter inside the app sandbox on macOS, iPadOS, and iOS. The embedded runtime exposes the complete PyMOL API (`from pymol import cmd`):

- **Interactive command line:** The command line in RayMol executes statements via PyMOL's standard command parsing and Python dispatch.
- **Scientific libraries:** Python environments in RayMol ship with essential numerical packages such as NumPy, allowing custom analysis scripts to run directly on-device.
- **Thread safety:** Calls into PyMOL's Python layer are coordinated with the app's main dispatch queue to avoid concurrency conflicts with live Metal frame generation.

## Metal rendering pipeline

RayMol replaces the legacy OpenGL viewport with a native Apple Metal renderer designed for Apple Silicon's Unified Memory Architecture (UMA). Geometry generated by the C++ engine is transferred directly to GPU-accessible buffers with minimal CPU-GPU copying.

Key architectural features of the Metal renderer include:

- **Analytic impostors:** Atoms (spheres) and bonds (cylinders) are rendered as screen-aligned analytic impostors. Pixel shaders evaluate ray-sphere and ray-cylinder intersections mathematically, delivering mathematically perfect curved surfaces at high frame rates without polygon tessellation.
- **Spline cartoons:** helices, sheets and loops are built from one natural cubic spline per cartoon segment, with parallel-transported twist frames, then extruded into ribbons and tubes with configurable cross-sections.
- **Weighted-blended transparency (WBOIT):** Translucent molecular surfaces and cartoon layers accumulate depth and color weights into multiple render targets simultaneously. This enables real-time order-independent transparency without expensive CPU-side depth sorting.
- **Hardware-accelerated ray tracing:** On supported Apple GPUs with hardware ray tracing cores, RayMol builds Metal acceleration structures (bounding volume hierarchies) over molecular geometry. This powers interactive ray-traced ambient occlusion, contact shadows, and realistic reflections.
- **Studio HDR lighting rigs:** A dedicated lighting subsystem models up to six positionable spot lights (key, fill, rim) alongside ambient warmth, Beer-Lambert atmospheric haze extinction, and volumetric dust particles.
- **Physically based materials:** Surfaces, cartoons, sticks, and spheres can each be assigned distinct material properties (such as `matte`, `plastic`, `metallic`, `glass`, `frosted_glass`, `jelly`, `marble`, `clay`, or `rubber`), with transparency peel controls for layered structures.
- **Post-processing pass:** Depth buffers and surface normals feed screen-space ambient occlusion (SSAO), depth cueing (fog), anti-aliasing, and silhouette contour lines.

## On-device machine learning (MLX)

RayMol integrates native machine learning inference directly on Apple Silicon through Apple's MLX framework:

- **Integrated models:** Supports structure prediction (Boltz-2 on all platforms, Protenix on macOS), generative backbone diffusion (RFdiffusion3, experimental, macOS only), and sequence design (ProteinMPNN).
- **Zero cloud round-trips:** Weights run on the device's GPU and CPU through MLX. Structures and sequences never leave the user's device.
- **Memory management:** Models need a lot of memory, so RayMol checks each job against the memory available before it starts and refuses one that would not fit, rather than letting the system kill the app.
- **Platform requirements:** On-device prediction and design are supported on macOS and iOS/iPadOS 18+ hardware devices (excluded on the iOS Simulator due to Metal private heap requirements). Protenix is macOS-only; Boltz-2 is available on all platforms.

## Model Context Protocol (MCP) server

RayMol includes a built-in Model Context Protocol server, turning RayMol into an AI-controllable molecular visualizer:

- **Transport:** Runs a small HTTP server on the local loopback interface (`127.0.0.1`, port `51737` by default) answering JSON-RPC 2.0 requests according to the Model Context Protocol specification. The server is off until you enable it with **Connect ▸ Enable AI control** (`⌃⌘M`, direct-download macOS build only).
- **Security:** The server listens on loopback only and every request must carry the bearer token. A client you did not start from RayMol's own Connect buttons must be approved in RayMol (**Allow**); once allowed, connections are trusted until the server is turned off.
- **Exposed capabilities:** AI assistants such as Claude Code and Claude for Mac can inspect loaded molecules, execute PyMOL commands, evaluate Python scripts, capture rendered viewports, and query the RCSB PDB.
- **Visual feedback:** When an AI tool drives RayMol, an interactive top banner indicates the active action and offers a one-click disconnect control.
- **Platform availability:** The MCP server is available in direct-download macOS builds. It is compiled out of sandboxed Mac App Store builds and iOS/iPadOS releases.

## Session format (.pse + RayMol extras)

RayMol reads and writes standard PyMOL `.pse` (PyMOL Session) files. The session format stores Python dictionaries serialized via Python's standard pickler.

RayMol preserves complete backward compatibility by storing its additions under custom session dictionary keys:
- `raymol_notes`: Analysis notes, named pages, interactive camera bookmarks, and embedded snapshot assets.
- `raymol_metrics`: Computed per-residue and whole-structure validation scores (such as pLDDT scores and PAE matrices).
- `raymol_msa`: stored multiple sequence alignments.
- `raymol_scene_*` (for example `raymol_scene_settings`, `raymol_scene_ttt`, `raymol_scene_lights`) and `raymol_movie_anim`: extended scene states and movie animation data.
- `light_rig`: the active studio light rig. Material choices are ordinary per-object settings and ride along in the standard session settings.

Upstream PyMOL ignores RayMol's extra session entries and shows the standard models and representations; RayMol-only settings and effects are simply absent.
