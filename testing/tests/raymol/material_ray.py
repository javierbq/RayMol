"""Materials under the CPU ray tracer (#499), and the glass surface it used to
trace opaque (#524).

`ray` has none of the Metal shaders. A material reaches it as the knobs its own
lighting model already has (layer1/Material.h, MaterialRayParams):

  * a `ray_texture` MODE -- marble Swirl 1 (2), clay and frosted_glass Matte 1
    (1), rubber Matte 2 (4). The texture's knobs stay `ray_texture_settings`,
    so a marble surface traces exactly as the same surface under
    `ray_texture 2`, and an explicit `ray_texture` wins;
  * a per-primitive highlight scale, diffuse scale and highlight tint -- matte
    loses its highlight, plastic brightens it, metallic dims the diffuse and
    tints the highlight toward the surface's own colour.

No setting is written, and `default` traces byte for byte as before.

Two kinds of assertion, deliberately:

  * the ACCESSOR `_cmd.get_material_ray_params` makes the same two calls
    CoordSet::render makes, so the mapping and its precedence are pinned
    exactly and cheaply;
  * the RENDERS prove the primitives actually carry it. They are traced with
    `max_threads 1`, because multi-threaded `ray` is not deterministic run to
    run (measured: max |diff| 6 for `default`) and single-threaded it is.
    Matte 1 and Matte 2 draw from rand(), so clay, rubber and frosted_glass can
    only be compared STRUCTURALLY -- by the high-frequency energy of the
    surface -- never byte for byte. Means are not used: a material is a claim
    about shading, and a mean barely moves when shading dies.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_ray.py
"""
import os
import tempfile

import numpy as np
from PIL import Image

from pymol import _cmd, cgo, cmd, testing
from pymol.constants import repres

W, H = 160, 130

# (ray_texture mode, material id, specular, diffuse, specTint) for a SURFACE.
# The ids must equal the enum in layer1/Material.h.
EXPECTED = {
    'default':       (0, 0, 1.0, 1.0, 0.0),
    'matte':         (0, 1, 0.0, 1.0, 0.0),
    'plastic':       (0, 2, 1.6, 1.0, 0.0),
    'metallic':      (0, 3, 1.4, 0.6, 0.8),
    'glass':         (0, 4, 1.0, 1.0, 0.0),
    'frosted_glass': (1, 5, 1.0, 1.0, 0.0),
    'jelly':         (0, 6, 1.0, 1.0, 0.0),
    'marble':        (2, 7, 1.0, 1.0, 0.0),
    'clay':          (1, 8, 1.0, 1.0, 0.0),
    'rubber':        (4, 9, 1.0, 1.0, 0.0),
}


def ray_params(obj, rep):
    return _cmd.get_material_ray_params(cmd._COb, obj, repres[rep])


def peptide(obj='m', rep='surface', material=None, colour='skyblue'):
    cmd.fab('ACDEFGHIKLMNPQRSTVWY', obj, ss=1)
    cmd.hide('everything', obj)
    cmd.show(rep, obj)
    cmd.color(colour, obj)
    if material:
        setting = {'sticks': 'stick', 'spheres': 'sphere'}.get(rep, rep)
        cmd.set('%s_material' % setting, material, obj)


def trace(tmpdir, tag):
    path = os.path.join(tmpdir, tag + '.png')
    cmd.png(path, width=W, height=H, ray=1)
    return np.asarray(Image.open(path).convert('RGB')).astype(float)


def fresh():
    """A clean scene for `ray`: single-threaded (deterministic), white
    background, and no depth cue or ray fog -- both fade distant surface
    toward the background, which lifts the red channel of a skyblue surface
    exactly the way a highlight does."""
    cmd.reinitialize()
    cmd.set('max_threads', 1)
    cmd.bg_color('white')
    cmd.set('ray_opaque_background', 1)
    cmd.set('depth_cue', 0)
    cmd.set('ray_trace_fog', 0)


def subject(img, erode=2):
    """Pixels that are not the white background, eroded so the silhouette's
    antialiased rim -- blended with white, so bright and unsaturated -- is not
    counted as surface."""
    mask = np.abs(img - 255.0).sum(axis=2) > 12
    for _ in range(erode):
        m = mask.copy()
        m[1:, :] &= mask[:-1, :]
        m[:-1, :] &= mask[1:, :]
        m[:, 1:] &= mask[:, :-1]
        m[:, :-1] &= mask[:, 1:]
        mask = m
    return mask


def hf_energy(img):
    """Mean |discrete Laplacian| of the luminance over the subject: the
    high-frequency content a bump texture adds and a smooth surface lacks."""
    lum = img.mean(axis=2)
    lap = (4 * lum[1:-1, 1:-1] - lum[:-2, 1:-1] - lum[2:, 1:-1]
           - lum[1:-1, :-2] - lum[1:-1, 2:])
    return float(np.abs(lap)[subject(img)[1:-1, 1:-1]].mean())


def changed_share(a, b):
    """Share of the frame differing by more than 8/255 in any channel."""
    return float((np.abs(a - b).max(axis=2) > 8).mean())


class _RayCase(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        fresh()
        self.tmp = tempfile.mkdtemp()

    def frame(self):
        cmd.orient('all')
        cmd.set_view(cmd.get_view())


class TestTheMapping(_RayCase):
    """What `ray` is HANDED per representation. No rendering."""

    def testEveryMaterialMapsToItsRayParams(self):
        peptide()
        for name, want in EXPECTED.items():
            cmd.set('surface_material', name, 'm')
            got = ray_params('m', 'surface')
            self.assertEqual(got[:2], want[:2], name)
            for g, w in zip(got[2:], want[2:]):
                self.assertAlmostEqual(g, w, places=5, msg=name)

    def testTheMappingReachesEveryMaterialRep(self):
        peptide(rep='cartoon')
        cmd.show('sticks', 'm')
        cmd.show('spheres', 'm')
        for rep, setting in (('cartoon', 'cartoon_material'),
                             ('sticks', 'stick_material'),
                             ('spheres', 'sphere_material')):
            cmd.set(setting, 'marble', 'm')
            self.assertEqual(ray_params('m', rep)[:2], (2, 7), rep)

    def testMaterialDefaultReachesRayToo(self):
        peptide()
        cmd.set('material_default', 'clay')
        self.assertEqual(ray_params('m', 'surface')[:2], (1, 8))

    def testRepsWithoutAMaterialGetNothing(self):
        # material_default does not reach lines, and lines take no material.
        peptide(rep='lines')
        cmd.set('material_default', 'marble')
        self.assertEqual(ray_params('m', 'lines'), (0, 0, 1.0, 1.0, 0.0))

    def testAnExplicitRayTextureWins(self):
        peptide(material='marble')
        cmd.set('ray_texture', 1, 'm')
        self.assertEqual(ray_params('m', 'surface')[0], 1)
        cmd.unset('ray_texture', 'm')
        cmd.set('ray_texture', 4)
        self.assertEqual(ray_params('m', 'surface')[0], 4)
        # ...and the highlight knobs are the material's either way: the
        # precedence rule is about the texture only.
        cmd.set('surface_material', 'metallic', 'm')
        self.assertEqual(ray_params('m', 'surface')[:2], (4, 3))

    def testAnObjectLevelZeroIsExplicitToo(self):
        # Set on the object, 0 is a choice -- "trace this marble without the
        # swirl" -- and it beats both the material and a non-zero global.
        peptide(material='marble')
        cmd.set('ray_texture', 0, 'm')
        self.assertEqual(ray_params('m', 'surface')[0], 0)
        cmd.set('ray_texture', 4)
        self.assertEqual(ray_params('m', 'surface')[0], 0)
        # Unset, the global 4 is explicit again...
        cmd.unset('ray_texture', 'm')
        self.assertEqual(ray_params('m', 'surface')[0], 4)
        # ...and a global 0 is not: it is also the default.
        cmd.set('ray_texture', 0)
        self.assertEqual(ray_params('m', 'surface')[0], 2)

    def testRayFollowsTheDrawDegradations(self):
        # glass has no sphere-impostor path and degrades to default there --
        # so under `ray` a frosted_glass sphere must not pick up the frost
        # texture either, or the viewport and the export disagree about what
        # the rep is made of.
        peptide(rep='spheres', material='frosted_glass')
        self.assertEqual(ray_params('m', 'spheres'), (0, 0, 1.0, 1.0, 0.0))
        # glass on a stick rep that emits stick_ball spheres: the whole rep
        # degrades.
        cmd.show('sticks', 'm')
        cmd.set('stick_material', 'frosted_glass', 'm')
        self.assertEqual(ray_params('m', 'sticks')[:2], (1, 5))
        cmd.set('stick_ball', 1, 'm')
        self.assertEqual(ray_params('m', 'sticks')[:2], (0, 0))

    def testJellyOnSpheresAndBallAndStickTracesAsJelly(self):
        # Jelly is the exception to both degradations above (#526).
        peptide(rep='spheres', material='jelly')
        self.assertEqual(ray_params('m', 'spheres'), EXPECTED['jelly'])
        cmd.show('sticks', 'm')
        cmd.set('stick_material', 'jelly', 'm')
        cmd.set('stick_ball', 1, 'm')
        self.assertEqual(ray_params('m', 'sticks'), EXPECTED['jelly'])


class TestTheRenders(_RayCase):
    """What the primitives actually CARRY."""

    def render(self, material=None, tex=None, rep='surface', tag=None):
        fresh()
        peptide(rep=rep, material=material)
        if tex is not None:
            cmd.set('ray_texture', tex, 'm')
        self.frame()
        return trace(self.tmp, tag or '%s_%s_%s' % (rep, material, tex))

    def testDefaultIsTheSameImageAsNoMaterialAtAll(self):
        # Setting `default` explicitly must not take any new path.
        a = self.render()
        b = self.render(material='default')
        self.assertTrue(np.array_equal(a, b))

    def testEveryMaterialTracesDifferentlyFromDefault(self):
        base = self.render()
        for name in EXPECTED:
            if name == 'default':
                continue
            share = changed_share(self.render(material=name), base)
            self.assertGreater(share, 0.01, name)

    def testAnObjectLevelZeroTracesMarbleWithoutTheSwirl(self):
        marble = self.render(material='marble', tex=0)
        # material still applies its (neutral) highlight knobs, so this is the
        # default image exactly
        self.assertTrue(np.array_equal(marble, self.render()))

    def testMarbleTracesExactlyAsSwirl1(self):
        marble = self.render(material='marble')
        swirl = self.render(tex=2)
        self.assertTrue(np.array_equal(marble, swirl))
        self.assertGreater(changed_share(marble, self.render()), 0.05)

    def testTheMatteModesTraceTheirTexture(self):
        # Random textures: compared by high-frequency energy, not by pixels.
        smooth = hf_energy(self.render())
        for name, tex in (('clay', 1), ('rubber', 4)):
            mat = hf_energy(self.render(material=name))
            explicit = hf_energy(self.render(tex=tex))
            self.assertGreater(mat, 1.3 * smooth, name)
            self.assertLess(abs(mat - explicit), 0.1 * explicit, name)

    def testFrostedGlassIsItsTransparencyPlusMatte1(self):
        # frosted_glass implies alpha 0.2 (transparency 0.8), not glass's
        # 0.15, so its explicit twin is `default` at transparency 0.8 under
        # ray_texture 1 -- and the frost texture is the only thing `ray`
        # adds on top of the transparency.
        clear = hf_energy(self.render(material='glass'))
        frosted = hf_energy(self.render(material='frosted_glass'))
        cmd.set('surface_material', 'default', 'm')
        cmd.set('transparency', 0.8, 'm')
        cmd.set('ray_texture', 1, 'm')
        explicit = hf_energy(trace(self.tmp, 'frost_twin'))
        self.assertGreater(frosted, 1.3 * clear)
        self.assertLess(abs(frosted - explicit), 0.1 * explicit)

    def highlight_pixels(self, img):
        """The specular highlight: subject pixels whose RED channel is lifted
        well past anything skyblue's lit diffuse reaches. skyblue is
        (0.2, 0.5, 0.8), so red is the channel only white light raises."""
        return subject(img) & (img[..., 0] > 150)

    def testMatteHasNoHighlight(self):
        self.assertGreater(self.highlight_pixels(self.render()).sum(), 20)
        self.assertEqual(
            self.highlight_pixels(self.render(material='matte')).sum(), 0)

    def testPlasticBrightensTheHighlight(self):
        default = self.highlight_pixels(self.render()).sum()
        plastic = self.highlight_pixels(self.render(material='plastic')).sum()
        self.assertGreater(plastic, 1.3 * default)

    def testMetallicTintsTheHighlightAndDimsTheBody(self):
        base = self.render()
        metal = self.render(material='metallic')
        # The brightest 1% of the subject: near-white on default, blue on
        # metallic (the highlight mixed toward skyblue).
        def top_tint(img):
            px = img[subject(img)]
            lum = px.mean(axis=1)
            top = px[lum >= np.percentile(lum, 99)]
            return float((top[:, 2] - top[:, 0]).mean())
        self.assertGreater(top_tint(metal), top_tint(base) + 30)
        # ...and the lit body is darker: the diffuse term is scaled.
        self.assertLess(np.median(metal[subject(metal)].mean(axis=1)),
                        np.median(base[subject(base)].mean(axis=1)) - 10)

    def testNoSettingIsWritten(self):
        self.render(material='marble')
        self.assertEqual(cmd.get_setting_int('ray_texture'), 0)
        self.assertEqual(cmd.get_setting_int('ray_texture', 'm'), 0)
        self.assertEqual(cmd.get_setting_float('specular'),
                         cmd.get_setting_float('specular', 'm'))


class TestNothingLeaksPastTheRep(_RayCase):
    """CoordSet::render re-arms the tracer after every material rep. Without
    that, whatever `ray` adds next -- another object's CGO -- would inherit the
    last rep's texture and highlight knobs."""

    def ball_region(self, material):
        fresh()
        peptide(material=material)
        # A CGO sphere far to the side, created AFTER the molecule so it is
        # traced after it.
        x, y, z = cmd.get_position()
        cmd.load_cgo([cgo.COLOR, 1.0, 1.0, 1.0,
                      cgo.SPHERE, x + 60.0, y, z, 12.0], 'ball')
        cmd.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1,
                      0, 0, -220, x + 30.0, y, z, 180, 260, 0))
        img = trace(self.tmp, 'leak_%s' % material)
        return img[:, W // 2:]   # the ball's half of the frame

    def testAMaterialStaysOnItsOwnObject(self):
        plain = self.ball_region('default')
        for name in ('marble', 'metallic', 'matte'):
            self.assertTrue(np.array_equal(self.ball_region(name), plain),
                            name)


class TestGlassSurfaceUnderRay(_RayCase):
    """#524: a glass surface traced opaque when uniformly coloured -- the ray
    path read the RAW transparency, while a multi-coloured surface took the
    per-vertex array the build had already baked the implied alpha into."""

    def red_behind(self, material, multi, rep='surface'):
        fresh()
        peptide(rep=rep, material=material, colour='grey80')
        if multi:
            cmd.color('grey70', 'm and elem N')
        self.frame()
        v = cmd.get_view()
        # A big red ball behind the surface, filling the frame.
        cmd.pseudoatom('ball', pos=cmd.get_position())
        cmd.hide('everything', 'ball')
        cmd.show('spheres', 'ball')
        cmd.set('sphere_scale', 30.0, 'ball')
        cmd.color('red', 'ball')
        cmd.translate([0, 0, -60], 'ball', camera=1)
        # keep the front clip, push the back one past the ball
        cmd.set_view(v[:16] + (v[16] + 120.0,) + v[17:])
        img = trace(self.tmp, 'behind_%s_%s_%d' % (rep, material, multi))
        # redness where the SUBJECT is: red above the other two channels.
        cmd.disable('ball')
        mask = subject(trace(self.tmp, 'mask_%s_%s_%d' % (rep, material,
                                                          multi)))
        red = img[..., 0] - (img[..., 1] + img[..., 2]) / 2
        return float(red[mask].mean())

    def testOneColourGlassIsTranslucent(self):
        opaque = self.red_behind('default', 0)
        one = self.red_behind('glass', 0)
        multi = self.red_behind('glass', 1)
        self.assertLess(opaque, 5)
        self.assertGreater(one, opaque + 40)
        # ...and one colour or two no longer decides how transparent it is.
        self.assertLess(abs(one - multi), 0.15 * multi)

    def testJellySpheresTraceWithJellysImpliedAlpha(self):
        # `ray` traces the sphere rep's built CGO, whose per-sphere alpha is
        # what the build resolved through the material (#526): a jelly sphere
        # is 85% opaque under `ray`, not solid.
        opaque = self.red_behind('default', 0, rep='spheres')
        jelly = self.red_behind('jelly', 0, rep='spheres')
        self.assertLess(opaque, 5)
        # measured ~32 against ~0 for default; 0.85 opacity is a small
        # share of red, so the bar sits well below it but far above noise
        self.assertGreater(jelly, opaque + 15)
