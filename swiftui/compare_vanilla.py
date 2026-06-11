"""
compare_vanilla.py — render a fixed set of representations in *vanilla* PyMOL
so you can compare them side-by-side against the SwiftUI+Metal PyMOL port.

The rep presets, colors, background, and camera here match exactly what the
Metal app test captures use, so the two are apples-to-apples.

WHICH MODE TO COMPARE
  - The Metal app is a real-time *rasterizer*. The fair comparison is vanilla
    PyMOL's real-time GL output ("realtime" mode) — NOT the ray tracer.
  - "ray" mode renders the gold-standard ray-traced reference (what perfect
    output looks like); useful as an upper bound, headless-friendly.

USAGE
  # Real-time GL — MUST run in the PyMOL GUI (needs a GL context):
  pymol swiftui/compare_vanilla.py

  # Ray-traced references (headless OK):
  pymol -cq swiftui/compare_vanilla.py -- ray

  # One representation only, custom structure / size:
  pymol swiftui/compare_vanilla.py -- realtime surface_transparent 2kpo 1000 750

  Args after `--`:  [mode] [rep|all] [structure] [width] [height]
    mode:  realtime (default) | ray
    rep:   all (default) | one of the names printed below

OUTPUT
  /tmp/vanilla_<rep>.png  for each representation.
  Open these next to the Metal app window (or reproduce the same view in the
  app by typing the same `hide/show/color/orient` commands in its terminal).
"""

import sys
from pymol import cmd, util

# ---------------------------------------------------------------------------
# Argument parsing. On the command line the args go after a literal `--`
# (so PyMOL doesn't try to interpret them); PyMOL strips the `--` and leaves
# them positionally in sys.argv after the script name.
# ---------------------------------------------------------------------------
_argv = sys.argv[1:]
MODE = _argv[0] if len(_argv) >= 1 else 'realtime'
ONLY = _argv[1] if len(_argv) >= 2 else 'all'
STRUCT = _argv[2] if len(_argv) >= 3 else \
    '/Users/jcastellanos/repos/pymol-open-source/1ubq.cif'
W = int(_argv[3]) if len(_argv) >= 4 else 1000
H = int(_argv[4]) if len(_argv) >= 5 else 750
RAY = (MODE == 'ray')

# ---------------------------------------------------------------------------
# Representation presets — keep IN SYNC with the Metal app test scenes.
# Each value is a function that configures the (already-hidden) molecule.
# ---------------------------------------------------------------------------
PRESETS = {
    'spheres':             lambda: cmd.show('spheres'),
    'sticks':              lambda: cmd.show('sticks'),
    'ballstick':           lambda: (cmd.show('sticks'), cmd.show('spheres'),
                                    cmd.set('sphere_scale', 0.25),
                                    util.cbag('mol')),
    'cartoon':             lambda: (cmd.show('cartoon'), cmd.spectrum()),
    'surface':             lambda: (cmd.show('surface'),
                                    cmd.color('grey80')),
    'surface_transparent': lambda: (cmd.show('cartoon'), cmd.show('surface'),
                                    cmd.set('transparency', 0.5),
                                    cmd.color('cyan', 'ss S'),
                                    cmd.color('salmon', 'ss H'),
                                    cmd.color('grey80', "ss L+''")),
    'spheres_transparent': lambda: (cmd.show('cartoon'),
                                    cmd.show('spheres', 'resn LYS+ARG'),
                                    cmd.set('sphere_transparency', 0.5),
                                    cmd.color('yellow', 'resn LYS+ARG')),
    'sticks_transparent':  lambda: (cmd.show('cartoon'), cmd.show('sticks'),
                                    cmd.set('stick_transparency', 0.6),
                                    cmd.color('orange')),
    'mesh':                lambda: (cmd.show('mesh'), cmd.color('cyan')),
    'lines':               lambda: cmd.show('lines'),
    'ribbon':              lambda: (cmd.show('ribbon'), cmd.spectrum()),
    'dots':                lambda: (cmd.show('dots'), cmd.color('yellow')),
}

# ---------------------------------------------------------------------------
# Scene setup (match the Metal app's defaults as closely as vanilla allows)
# ---------------------------------------------------------------------------
cmd.reinitialize()
cmd.load(STRUCT, 'mol')
cmd.bg_color('black')
cmd.viewport(W, H)
cmd.set('ray_opaque_background', 1)
# The Metal app keeps anti-aliasing + depth-cue/fog on by default.
cmd.set('antialias_shader', 2)   # vanilla GL SMAA (Metal app uses FXAA)
cmd.set('depth_cue', 1)
cmd.set('fog', 1)
if RAY:
    # Ray tracer can do shadows + ambient occlusion (the Metal app approximates
    # these in screen space); turn them on for the gold-standard reference.
    cmd.set('ray_shadows', 1)
    cmd.set('ambient_occlusion_mode', 1)

cmd.orient()
_VIEW = cmd.get_view()          # lock one camera for every rep


def shot(name):
    cmd.hide('everything')
    PRESETS[name]()
    cmd.set_view(_VIEW)         # identical camera across reps
    out = '/tmp/vanilla_%s.png' % name
    if RAY:
        cmd.ray(W, H)
        cmd.png(out, dpi=72, ray=0)
    else:
        # Real-time GL: draw the scene (GUI only), then save the framebuffer.
        cmd.draw(W, H, antialias=1)
        cmd.png(out, dpi=72, ray=0)
    print('  saved', out)


names = list(PRESETS) if ONLY == 'all' else [ONLY]
print('compare_vanilla: mode=%s  structure=%s  %dx%d' % (MODE, STRUCT, W, H))
for n in names:
    if n not in PRESETS:
        print('  ! unknown rep "%s"; choices: %s' % (n, ', '.join(PRESETS)))
        continue
    shot(n)
print('Done. Compare /tmp/vanilla_*.png against the Metal app '
      '(same hide/show/color/orient commands reproduce each view).')
