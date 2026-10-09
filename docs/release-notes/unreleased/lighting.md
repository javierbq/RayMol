<!--
Draft section for the next macOS release (#627, the lighting epic #610).
The release cut (cut-macos-release) picks the version, writes
docs/release-notes/vX.Y.Z.md with its own headline, moves the
"### Studio lights" section below into it, and deletes this file. From
docs/release-notes/ the guide's link becomes ../lighting.md. macOS-facing
only: the iPhone and iPad items are in #627's PR body, for cut-ios-release.
-->
## RayMol — next release (draft)

A feature release built around **studio lights**: spot lights you place around the molecule, each with its own colour, beam and shadow, shining through haze and floating dust.

### Studio lights

- **Light the scene like a photo studio.** A rig holds up to six spot lights. Each has its own place around the molecule, colour, warmth, beam width and edge softness, brightness and highlight, and any three of them can cast their own shadows. The rig belongs to the scene: it never changes an object's colours, materials or settings, and `lights off` gives PyMOL's own lighting back exactly as it was.
- **Seven presets to start from:** `three_point`, `softbox`, `spotlight`, `rembrandt`, `neon`, `sunset` and `underlight`. Type `lights three_point`, or pick one from **Presets** in Lights mode.
- **Lights mode.** Choose **Enter Lights Mode** in the **Tools** menu. A bar at the top of the viewport holds a chip per light, **Presets**, **Re-centre**, the on/off switch, **Revert** and **Done**. Beside the scene, an orbit view shows the rig from above (drag a lamp round it, drag the square on its ring for the distance, and the pitch arc for the height), and the inspector below it holds each light's exact values, its colour, and the **Shadow** and **Pin** switches.
- **Knobs on the molecule.** In Lights mode every light is a knob on a sphere around the molecule: drag it to move the light, drag the selected light's rings to set its beam and softness, drag its aim dot to point it at the surface under the pointer, and scroll over it to move it closer or further. Option-click the molecule to put a highlight exactly there.
- **Or type it.** `lights key, warmth=3800, intensity=1.3` edits a light, `lights add, back, orbit=180` adds one, and `lights` prints the rig. `target=` aims a light at a selection and fits the beam to it; `highlight=` places a light so the selection shows a highlight, and `rim=` turns that into a rim light. Camera lights follow your view; `pin=1` fixes a light in the scene so it turns with the molecule. The same rig is `cmd.lights`, `cmd.get_lights` and `cmd.set_lights` from Python.
- **Coloured shadows, one per light.** A red light's shadow is where the red light does not reach. Studio shadows work with Metal ray tracing on or off, and in grid mode each cell is shadowed only by its own objects. They need the scene's **Shadows** switch on; the inspector offers **Turn On** when it is off.
- **Haze and dust.** `atmosphere haze=0.3, dust=0.5`, or the new **Atmosphere** card in Lights mode (**Haze**, **Dust**, **Dust size**, **Dust speed**, and **Scatter (g)**), fills the beams with haze and floating dust. A shadowed light casts light shafts through the haze. The dust drifts in the live view at up to 30 redraws a second, only while RayMol is active and its window visible, and holds still in Low Power Mode or when the Mac runs hot; `metal_light_air_time` pins it for repeatable renders. The card's hints say why the air does not show (no light, or the lights off) and warn when haze with a light behind the molecule can wash the picture out.
- **Bright lights keep their colour.** Under a rig, light is kept in high dynamic range and rolled off once at the end, so a bright coloured light rolls off towards white keeping its hue instead of whitening early, up to `intensity` 4. With a rig on, **Exposure** (`metal_exposure`) now scales what the lights light and the air, not the background or labels, which makes it the way to tame a bright rig or backlit haze. `set metal_light_hdr, 2` brings back the 8-bit look.
- **Saved with your work.** Sessions save the rig and its air. Each scene stores its own rig, recalling a scene brings it back, and scene movies blend the lights and the air from scene to scene with the camera.
- **Exports keep the look.** Image exports from the app, **Ray-traced (AO + shadows)** included, render with Metal and keep the studio lights. PyMOL's CPU `ray` command (and `png ..., ray=1`) keeps PyMOL's own lights and prints a one-line note saying so.
- **No rig, no change.** Without a rig every image is exactly the one the previous version drew, so existing sessions look the same.

See [docs/lighting.md](../../lighting.md) for every command, field and setting, the Lights mode controls, performance switches and the known limits.

Built on the open-source PyMOL engine. Updates install automatically via the in-app updater (**Check for Updates…** in the app menu).
