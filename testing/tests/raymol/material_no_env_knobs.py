"""No material is tuned by an environment variable (#502).

The prototype (`proto/rt-self-reflections`) read every material knob from a
`RAYMOL_*` environment variable -- `RAYMOL_MATERIAL`, `RAYMOL_MARBLE_*`,
`RAYMOL_GLASS_*`, `RAYMOL_RUBBER_*`, `RAYMOL_MAT_P*`, `RAYMOL_WAX_*`,
`RAYMOL_OIT_PEEL` -- and its render scripts drove the reflection through
`RAYMOL_RT_REFLECT*`. The epic ported each one BY HAND into the material table and
the settings, so a shipped build reads none of them. This file keeps it that
way: a knob that comes back as a getenv would render differently depending on
the shell the app was launched from, invisibly to `.pse`, `get` and every test.

It is a literal scan: a line that NAMES a knob fails it, comments included
(write "the prototype's marble scale knob", not the variable), and a name
assembled from pieces at runtime is not seen.

Source-reading, so skipped (not passed) outside a repo checkout.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_no_env_knobs.py
"""
import os
import re

from pymol import testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))

# Every RAYMOL_ name the prototype read that tuned a material, spelled out
# rather than derived, so a returning knob is caught by NAME and not only by
# prefix: 25 read by its renderer, and the five RT_REFLECT names its render
# scripts (prototype_renders/scripts) turned into metal_rt_reflect* settings
# (since retired, #565).
PROTOTYPE_MATERIAL_KNOBS = (
    'RAYMOL_MATERIAL',
    'RAYMOL_GLASS_COVER', 'RAYMOL_GLASS_FROST', 'RAYMOL_GLASS_IOR',
    'RAYMOL_GLASS_REFLECT', 'RAYMOL_GLASS_THICK', 'RAYMOL_GLASS_TINT',
    'RAYMOL_MARBLE_SCALE', 'RAYMOL_MARBLE_SHARP', 'RAYMOL_MARBLE_VEIN',
    'RAYMOL_MARBLE_VEIN_RGB', 'RAYMOL_MARBLE_WRAP',
    'RAYMOL_MAT_P0', 'RAYMOL_MAT_P1', 'RAYMOL_MAT_P2', 'RAYMOL_MAT_P3',
    'RAYMOL_RUBBER_FREQ', 'RAYMOL_RUBBER_GRAIN', 'RAYMOL_RUBBER_SHEEN',
    'RAYMOL_RUBBER_SPEC',
    'RAYMOL_WAX_P0', 'RAYMOL_WAX_P1', 'RAYMOL_WAX_P2', 'RAYMOL_WAX_P3',
    'RAYMOL_OIT_PEEL',
    'RAYMOL_RT_REFLECT', 'RAYMOL_RT_REFLECT_ENV', 'RAYMOL_RT_REFLECT_ROUGH',
    'RAYMOL_RT_REFLECT_SAMPLES', 'RAYMOL_RT_REFLECT_TINT',
)

# ...and their families -- the eight #502 names, plus the shipped material
# names -- so a NEW knob in one of them is caught too.
MATERIAL_KNOB = re.compile(
    r'RAYMOL_(MATERIAL|MARBLE_|GLASS_|RUBBER_|MAT_P|WAX_|RT_REFLECT|OIT_PEEL'
    r'|JELLY|CLAY|MATTE|PLASTIC|METALLIC|FROST)')

# The one RAYMOL_ read the Metal renderer keeps: a frame-timing log, written to
# a file, which changes nothing that is drawn and can serve #501's frames/s
# measurements. It predates the epic (fa6b1c347, 2026-09-03).
METAL_ALLOWED = {'RAYMOL_GPU_TIMING'}

SHIPPED_DIRS = ('layer0', 'layer1', 'layer2', 'layer3', 'layer4', 'layer5',
                'layerGraphics', 'modules/pymol', 'modules/raymol_mcp',
                'swiftui/PyMOLViewer')
SOURCE_EXT = ('.c', '.cpp', '.h', '.hpp', '.m', '.mm', '.swift', '.py',
              '.metal')


def sources(subdir):
    top = os.path.join(ROOT, subdir)
    for dirpath, _dirs, files in os.walk(top):
        for name in files:
            if name.endswith(SOURCE_EXT):
                path = os.path.join(dirpath, name)
                with open(path, encoding='utf-8', errors='replace') as handle:
                    yield os.path.relpath(path, ROOT), handle.read()


class TestNoMaterialEnvKnobs(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        if not os.path.isdir(os.path.join(ROOT, 'layerGraphics', 'metal')):
            # Skipped, not passed: a source-reading test that cannot find its
            # source has checked nothing.
            self.skipTest('layerGraphics/metal not present; not a repo checkout')

    def testTheMetalRendererReadsNoRaymolVariableButTheTimingLog(self):
        found = {}
        for path, text in sources('layerGraphics/metal'):
            for name in re.findall(r'RAYMOL_[A-Z0-9_]+', text):
                found.setdefault(name, set()).add(path)
        stray = {n: sorted(p) for n, p in found.items()
                 if n not in METAL_ALLOWED}
        self.assertEqual(stray, {})

    def testNoShippedSourceNamesAMaterialKnob(self):
        # os.walk of a missing directory yields nothing, so a renamed tree
        # would pass this silently; every one must exist and hold sources.
        for subdir in SHIPPED_DIRS:
            self.assertTrue(any(True for _ in sources(subdir)),
                            '%s is missing or has no sources' % subdir)
        hits = []
        for subdir in SHIPPED_DIRS:
            for path, text in sources(subdir):
                for lineno, line in enumerate(text.splitlines(), 1):
                    if MATERIAL_KNOB.search(line) or any(
                            k in line for k in PROTOTYPE_MATERIAL_KNOBS):
                        hits.append('%s:%d: %s' % (path, lineno, line.strip()))
        self.assertEqual(hits, [])

    def testThePatternCoversTheFamiliesNotJustTheNames(self):
        # The scan above checks the named knobs literally, so the regex only
        # earns its place for names NOT in the tuple. Check it on exactly
        # those: one new name per family.
        for knob in ('RAYMOL_MATERIAL_ID', 'RAYMOL_MARBLE_NEWKNOB',
                     'RAYMOL_GLASS_ABSORB', 'RAYMOL_RUBBER_BUMP',
                     'RAYMOL_MAT_P4', 'RAYMOL_WAX_P4',
                     'RAYMOL_RT_REFLECT_BIAS', 'RAYMOL_OIT_PEEL_K',
                     'RAYMOL_JELLY_ABSORB', 'RAYMOL_CLAY_GRAIN',
                     'RAYMOL_MATTE_WRAP', 'RAYMOL_PLASTIC_SPEC',
                     'RAYMOL_METALLIC_TINT', 'RAYMOL_FROST_TAPS'):
            self.assertNotIn(knob, PROTOTYPE_MATERIAL_KNOBS)
            self.assertTrue(MATERIAL_KNOB.search(knob), knob)
        self.assertFalse(MATERIAL_KNOB.search('RAYMOL_GPU_TIMING'))
        self.assertFalse(MATERIAL_KNOB.search('RAYMOL_MCP_PORT'))
