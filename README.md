<img src="./swiftui/PyMOLViewer/Resources/RayMol.svg" height="100" align="right" />

# RayMol

**RayMol** is a native **macOS · iPad · iPhone** reimagining of the
[PyMOL](https://pymol.org) molecular visualization system — a SwiftUI front end
driving the real PyMOL engine through **Metal**, with an embedded CPython
runtime so the full `pymol` Python API runs on-device.

It is a fork of [open-source PyMOL](https://github.com/schrodinger/pymol-open-source):
the C++ rendering and chemistry core is preserved, the OpenGL pipeline is
replaced with a modern Metal renderer, and a touch- and pointer-native UI is
built on top.

## Highlights

- **Metal rendering pipeline** — impostor ray-cast spheres & cylinders,
  tessellated cartoon tubes, MSAA, SSAO, real-time shadow mapping, order-
  independent transparency, and toon/silhouette outlines.
- **Hardware ray tracing** — real-time ambient occlusion + shadows via a Metal
  acceleration structure (`metal_raytrace`) on Apple-silicon GPUs, plus a
  Metal-accelerated hi-res ray export.
- **Native, responsive UI** — a SwiftUI inspector for per-structure
  representations, a sequence panel, interactive measurements, a timeline /
  movie builder, and an adaptive layout spanning Mac, iPad, and iPhone.
- **Raymond, the AI assistant** *(experimental, off by default)* — an in-app
  copilot that drives PyMOL via natural language.
- **Theme Studio** — a live-preview theming system (Classic · Paper · Sunset ·
  Dawn presets + custom themes) controlling both app chrome and molecular
  defaults.

## Building

The cross-platform app lives in [`swiftui/`](swiftui) (Xcode project +
embedded-Python tooling). The PyMOL core builds as before:

- App: open `swiftui/PyMOLViewer.xcodeproj` and build the
  `PyMOLViewer_macOS` / `PyMOLViewer_iOS` scheme.
- Core / classic PyMOL: see [INSTALL](INSTALL).

## Contributing

See [DEVELOPERS](DEVELOPERS).

## Credits & License

RayMol is built on **PyMOL**, Copyright (c)
[Schrödinger, LLC](https://www.schrodinger.com/), and is published under the
same BSD-like license — see [LICENSE](LICENSE). PyMOL is a trademark of
Schrödinger, LLC; RayMol is an independent fork and is not affiliated with or
endorsed by Schrödinger.
