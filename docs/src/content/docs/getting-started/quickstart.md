---
title: Quickstart
description: Load your first structure and create an interactive molecular scene.
---

## 1. Fetch a structure

Open RayMol's command console and fetch ubiquitin from the RCSB Protein Data Bank:

```text
fetch 1ubq, async=0
```

You can also choose **Open File…** to load a local structure or PyMOL session.

## 2. Choose a representation

Use the **Objects** inspector, or enter familiar PyMOL commands:

```text
hide everything, 1ubq
show cartoon, 1ubq
spectrum count, rainbow, 1ubq
```

## 3. Improve the lighting

Open the **Display** inspector to adjust shadows, ambient occlusion, outlines, and supported hardware ray-tracing effects while watching the Metal viewport update.

## 4. Save your work

Save a `.pse` session to preserve the scene. Use the **Export** menu to save or share an image, structure, session, or authored movie.
