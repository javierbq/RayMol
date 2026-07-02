# Release-notes style (`docs/release-notes/vX.Y.Z.md`)

These notes are user-facing: they render inside the Sparkle update dialog (as Markdown) and become the GitHub release body. Write for a RayMol *user*, not a developer.

## Rules

- **macOS-facing only.** RayMol ships macOS via Sparkle and iOS via the App Store. Changes that only touch the iOS path do NOT belong in the macOS notes — they never reach these users. When a release's headline features are iOS-only, the macOS notes may be a small fixes list; that's fine.
- **Describe user-visible behavior, not code.** "Surfaces return to opaque when recolored" — not "reset the transparency flag in CGOGL". Name where a control lives when useful (*Scene ▸ Camera*).
- **Lead with the headline.** One sentence up top framing the release (feature release vs stability/patch).
- **Group by area** for feature releases (Rendering, Inspector, Command line, …). A single-fix patch can be one bullet.
- **Bold the change, then explain.** `**Fixed: dark triangles on cartoons with shadows on.** …`
- **Always end with the footer:**
  `Built on the open-source PyMOL engine. Updates install automatically via the in-app updater (**Check for Updates…** in the app menu).`

## Patch release example (v1.5.1)

```markdown
## RayMol 1.5.1

A rendering fix for cartoons under shadows.

- **Fixed: dark triangles on cartoons with shadows on.** With Metal shadows
  enabled, the coarse cartoon mesh could self-shadow into a faceted look.
  Shadows now use a scale-aware normal-offset bias so cartoons stay clean —
  while shadows cast *between* elements (helix onto sheet, sticks onto surface)
  are preserved.

Built on the open-source PyMOL engine. Updates install automatically via the in-app updater (**Check for Updates…** in the app menu).
```

## Feature release example (excerpt, v1.5.0)

```markdown
## RayMol 1.5.0

A feature release: richer surface rendering, a reorganized inspector, and a
batch of Metal fidelity fixes.

### Surfaces
- **Outer-contour outline.** A crisp silhouette around surfaces — holds up on
  transparent and clipped surfaces — *Scene / Surface card*.
- **Per-representation clipping.** Clip a surface independently of the slab.

### Command line
- **Clicking the viewport no longer steals focus** from the command line, and
  **up/down history** works again.

Built on the open-source PyMOL engine. Updates install automatically via the in-app updater (**Check for Updates…** in the app menu).
```
