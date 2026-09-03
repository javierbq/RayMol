'''
cartoon_spline: ChimeraX-style natural-cubic-spline cartoon path tessellation
(alternative to the classic per-residue Hermite blend, selected per object
or globally with the cartoon_spline setting).
'''

from pymol import cmd, testing


class TestCartoonSpline(testing.PyMOLTestCase):

    def _render(self, spline, sampling=-1):
        cmd.reinitialize()
        cmd.viewport(200, 200)
        cmd.load(self.datafile('1oky-frag.pdb'), 'm1')
        cmd.dss('m1')
        cmd.hide('everything')
        cmd.show('cartoon')
        cmd.set('cartoon_spline', spline)
        cmd.set('cartoon_sampling', sampling)
        cmd.orient()
        self.ambientOnly()
        cmd.color('red')
        cmd.set('opaque_background')
        cmd.bg_color('black')
        return self.get_imagearray(width=200, height=200, ray=1)

    def test_default_is_classic(self):
        self.assertEqual(cmd.get_setting_int('cartoon_spline'), 0)

    def test_spline_renders_cartoon(self):
        img = self._render(1)
        # the cartoon is drawn (red pixels present) and covers roughly the same
        # footprint as the classic tessellation
        self.assertImageHasColor('red', img)
        classic = self._render(0)
        n_spline = (img[..., 0] > 100).sum()
        n_classic = (classic[..., 0] > 100).sum()
        self.assertGreater(n_spline, 0)
        self.assertLess(abs(n_spline - n_classic) / float(n_classic), 0.25)

    def test_spline_differs_from_classic(self):
        # the two tessellations must not be pixel-identical
        self.assertImageNotEqual(self._render(1, 20), self._render(0, 20))

    def test_set_invalidates_cartoon(self):
        # changing the setting alone must rebuild the cartoon (no explicit rebuild)
        img_classic = self._render(0, 20)
        cmd.set('cartoon_spline', 1)
        img_spline = self.get_imagearray(width=200, height=200, ray=1)
        self.assertImageNotEqual(img_classic, img_spline)

    def test_spline_per_object(self):
        cmd.reinitialize()
        cmd.load(self.datafile('1oky-frag.pdb'), 'm1')
        cmd.load(self.datafile('1oky-frag.pdb'), 'm2')
        cmd.show('cartoon')
        cmd.set('cartoon_spline', 1, 'm2')
        cmd.set('cartoon_cylindrical_helices', 0)
        # must build both without error and keep the extents identical
        e1 = cmd.get_extent('m1')
        e2 = cmd.get_extent('m2')
        self.assertArrayEqual(e1, e2, delta=1e-3)
        cmd.rebuild()
        cmd.refresh()

    def test_spline_with_gaps_and_nucleic(self):
        # chain breaks, skipped residues and nucleic acid backbones take the
        # same code path; just make sure nothing blows up
        cmd.reinitialize()
        cmd.load(self.datafile('1ehz-5.pdb'), 'rna')
        cmd.load(self.datafile('1oky-frag.pdb'), 'prot')
        cmd.remove('prot and resi 20-25')
        cmd.cartoon('skip', 'prot and resi 40-42')
        cmd.set('cartoon_spline', 1)
        cmd.show('cartoon')
        cmd.rebuild()
        cmd.refresh()
        cmd.set('cartoon_sampling', 1)
        cmd.rebuild()
        cmd.refresh()
