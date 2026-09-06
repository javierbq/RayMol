---
title: Rendering & Export
description: Improve viewport quality and export images, structures, sessions, and movies.
---

## Tune the interactive view

Use the **Display** inspector to configure Metal rendering effects such as shadows, ambient occlusion, outlines, depth cueing, and transparency. Hardware ray-traced ambient occlusion and shadows are available on supported Apple Silicon GPUs.

## Export an image

Open **Export → Save Image** on macOS, or the share menu on iPad and iPhone. RayMol can export the current viewport size, a 2× image, or a 4K image where available. macOS also offers a custom image size.

Use **Render Options** to choose the high-resolution ray-traced path and a transparent background before exporting. Transparent output is written as PNG.

## Export molecular data

The export menu can save common structure formats including PDB, mmCIF, SDF, MOL, MOL2, XYZ, and PQR. Save a `.pse` session when you want to preserve the complete RayMol scene.

## Export a movie

Create an animation in the **Movie** inspector, then choose **Export Movie…**. RayMol renders the authored timeline in-app and exports MP4 or GIF output. Available options vary slightly by platform and device size.
