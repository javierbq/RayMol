---
title: Metal Engine Architecture
description: How RayMol combines PyMOL, SwiftUI, Python, and Metal on Apple platforms.
---

RayMol preserves PyMOL's C++ molecular and command engine while replacing its viewport path with a native Metal renderer. A SwiftUI application layer provides the adaptive Mac, iPad, and iPhone interface, and an embedded CPython 3.13 runtime exposes PyMOL's command API on-device.

## Rendering pipeline

- **Metal-native drawing:** RayMol renders common molecular representations through Metal, including analytic impostors for spheres and cylinders and tessellated cartoon geometry.
- **Unified-memory data flow:** Molecular geometry and render data remain close to the CPU and GPU on Apple Silicon, reducing unnecessary copies.
- **Weighted-blended transparency:** Transparent representations accumulate into offscreen targets and are resolved without per-object back-to-front sorting.
- **Hardware ray tracing:** On supported Apple GPUs, Metal acceleration structures provide interactive ray-traced ambient occlusion and shadows. This is distinct from PyMOL's high-quality CPU `ray` command.
- **Post-processing:** Shadow maps, screen-space ambient occlusion, anti-aliasing, fog, and outlines are combined in the final frame.

## Application layers

The SwiftUI interface communicates with PyMOL through an Objective-C++ bridge. Commands, sessions, selections, and molecular state remain grounded in PyMOL, while Apple-platform features such as document pickers, sharing, touch gestures, and the Metal view are implemented natively.
