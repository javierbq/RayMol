"""CPU `ray` and studio lights: Metal-only, with a notice (#626).

Studio lighting is drawn only by the Metal renderer. The CPU tracer keeps
PyMOL's own lights and never reads the rig, so a CPU image traced while the
rig is on prints one feedback line per command:

     Ray: studio lights are Metal-only; this ray-traced image uses PyMOL's lights.

The rig is on when it is enabled and has at least one light (and its frame).
The line comes from the core's three CPU-image entry points
(SceneLightsRayNotice, layer1/SceneLights.h): ExecutiveRay (`ray`, POV-Ray
immediate mode, the C API), the CPU branch of CmdPNG (`png ..., ray=1`, a
headless `png`, `save x.png`) and MovieModalPNG stage 2 (`mpng` in ray mode,
once per call). It is FB_Ray warnings feedback: it ignores `quiet`, and
`feedback disable, ray, warnings` silences it.

Covers: the accessor (_lights_ray_notice -> _cmd.get_lights_ray_notice); the
notice on every CPU path, exactly once per command; silence with no rig, a
disabled rig and an empty rig, and with the rig on when nothing is traced
(the prior image, the copy, the geometry test mode) or warnings are off; the
CPU image byte-identical with no rig, the rig on and the rig off; the MCP
`capture_viewport` result (the image first, then a `Note:` text item only
while the rig is on) and its description; and the policy note in the `ray`,
`png` and `mpng` docstrings.

C++ feedback is written straight to fd 1, so the console is captured there:
contextlib.redirect_stdout never sees it (as in lighting_session.py).

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_ray_notice.py
"""
import base64
import contextlib
import copy
import glob
import io
import os
import shutil
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

import pymol
import pymol.invocation
from pymol import _cmd, cmd, lighting, testing

import raymol_mcp.mainthread as mainthread
import raymol_mcp.tools as tools

NOTICE = "studio lights are Metal-only; this ray-traced image uses PyMOL's lights."
LINE = ' Ray: ' + NOTICE

# Three coloured lights, a shadow, air, and decision 15's terms away from
# their defaults (ambient 0.6, classic 0): if the rig or decision 15 ever
# leaked into the CPU tracer, TestCpuImageUnchanged would see it. No frame:
# set_lights captures it from the peptide.
RIG_ON = {
    'enabled': True,
    'ambient': 0.6,
    'classic': 0.0,
    'air': {'haze': 0.4},
    'lights': [
        {'name': 'key', 'orbit': -45, 'pitch': 35, 'shadow': True,
         'color': [1.0, 0.8, 0.6]},
        {'name': 'fill', 'orbit': 60, 'pitch': 10, 'color': [0.6, 0.8, 1.0]},
        {'name': 'rim', 'orbit': 160, 'pitch': 30, 'color': [0.0, 1.0, 1.0]},
    ],
}
RIG_OFF = dict(copy.deepcopy(RIG_ON), enabled=False)
RIG_EMPTY_ON = {'enabled': True, 'lights': []}
NOT_ON = {'none': None, 'off': RIG_OFF, 'empty': RIG_EMPTY_ON}

HEADLESS = bool(pymol.invocation.options.no_gui)
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'


@contextlib.contextmanager
def capture_console():
    """Collect what is written to fd 1 while open (yields a getter, read
    after the block). Copied from lighting_session.py."""
    sys.stdout.flush()
    saved = os.dup(1)
    tmp = tempfile.TemporaryFile(mode='w+b')
    result = {}
    try:
        os.dup2(tmp.fileno(), 1)
        yield lambda: result['text']
        sys.stdout.flush()
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        tmp.seek(0)
        result['text'] = tmp.read().decode(errors='replace')
        tmp.close()


def notices(text):
    return [line.rstrip() for line in text.splitlines()
            if 'studio lights are Metal-only' in line]


def png_size(path):
    with Image.open(path) as img:
        return img.size


class NoticeCase(testing.PyMOLTestCase):
    """A 3-residue peptide in sticks, traced single-threaded at tiny sizes.
    The viewport is 32 x 24, so a `png` or `save` with no size traces a tiny
    image too."""

    def setUp(self):
        super().setUp()  # reinitialize, feedback push
        cmd.set('max_threads', 1)
        cmd.viewport(32, 24)
        cmd.fab('AGA', 'pep')
        cmd.hide('everything')
        cmd.show('sticks', 'pep')
        cmd.orient()
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        cmd.set_lights(None)
        cmd.feedback('enable', 'ray', 'warnings')
        shutil.rmtree(self.tmpdir, ignore_errors=True)
        super().tearDown()  # feedback pop

    def path(self, name):
        return os.path.join(self.tmpdir, name)

    def lines(self, func):
        """The notice lines printed while `func` runs."""
        with capture_console() as text:
            func()
        return notices(text())


class TestAccessor(NoticeCase):
    """_lights_ray_notice() (and _cmd.get_lights_ray_notice): the text while
    the rig is on, else None. It reads the rig only; it prints nothing."""

    def test_no_rig(self):
        self.assertIsNone(cmd.get_lights())
        self.assertIsNone(lighting._lights_ray_notice())
        self.assertIsNone(_cmd.get_lights_ray_notice(cmd._COb))

    def test_rig_on(self):
        cmd.set_lights(RIG_ON)
        self.assertEqual(lighting._lights_ray_notice(), NOTICE)
        self.assertEqual(_cmd.get_lights_ray_notice(cmd._COb), NOTICE)
        self.assertEqual(self.lines(lighting._lights_ray_notice), [])

    @testing.foreach('off', 'empty')
    def test_rig_not_on(self, label):
        cmd.set_lights(NOT_ON[label])
        self.assertIsNotNone(cmd.get_lights(), label)
        self.assertIsNone(lighting._lights_ray_notice(), label)

    def test_removed(self):
        cmd.set_lights(RIG_ON)
        cmd.set_lights(None)
        self.assertIsNone(lighting._lights_ray_notice())

    def test_reinitialize(self):
        cmd.set_lights(RIG_ON)
        cmd.reinitialize()
        self.assertIsNone(lighting._lights_ray_notice())

    def test_follows_live_edits(self):
        # The app bridge's setter switches the rig off and on in place.
        cmd.set_lights(RIG_ON)
        lighting._light_set(-1, 'enabled', 0)
        self.assertIsNone(lighting._lights_ray_notice())
        lighting._light_set(-1, 'enabled', 1)
        self.assertEqual(lighting._lights_ray_notice(), NOTICE)


class TestNoticeFires(NoticeCase):
    """Rig on and a CPU image traced: exactly one line per command."""

    def setUp(self):
        super().setUp()
        cmd.set_lights(RIG_ON)

    def test_ray(self):
        self.assertEqual(self.lines(lambda: cmd.ray(24, 18)), [LINE])

    def test_ray_quiet_off(self):
        # A warning: printed whatever `quiet` says.
        self.assertEqual(self.lines(lambda: cmd.ray(24, 18, quiet=0)), [LINE])

    def test_ray_command(self):
        self.assertEqual(self.lines(lambda: cmd.do('ray 24, 18')), [LINE])

    def test_ray_twice(self):
        def twice():
            cmd.ray(24, 18)
            cmd.ray(24, 18)
        self.assertEqual(self.lines(twice), [LINE, LINE])

    def test_png_ray(self):
        path = self.path('ray.png')
        self.assertEqual(
            self.lines(lambda: cmd.png(path, 24, 18, ray=1)), [LINE])
        self.assertEqual(png_size(path), (24, 18))

    @unittest.skipUnless(HEADLESS, 'headless only: png traces with no GUI')
    def test_png_headless(self):
        # No ray=1: with no GUI, CmdPNG takes its CPU branch.
        path = self.path('headless.png')
        self.assertEqual(self.lines(lambda: cmd.png(path, 24, 18)), [LINE])
        self.assertEqual(png_size(path), (24, 18))

    def test_png_bytes(self):
        out = {}

        def run():
            out['data'] = cmd.png(None, 24, 18, ray=1)
        self.assertEqual(self.lines(run), [LINE])
        self.assertEqual(out['data'][:8], PNG_MAGIC)

    @unittest.skipUnless(HEADLESS, 'headless only: save traces with no GUI')
    def test_save_png(self):
        # save routes .png to cmd.png, which traces at the viewport size.
        path = self.path('saved.png')
        self.assertEqual(self.lines(lambda: cmd.save(path)), [LINE])
        self.assertEqual(png_size(path), tuple(cmd.get_viewport()))

    @unittest.skipUnless(HEADLESS, 'headless only: png traces with no GUI')
    def test_rig_change_retraces(self):
        cmd.ray(24, 18)
        # Setting the rig invalidates the copy (SceneSetLightRig ->
        # SceneInvalidate), so a `png` with no size traces again.
        cmd.set_lights(RIG_ON)
        path = self.path('retrace.png')
        self.assertEqual(self.lines(lambda: cmd.png(path)), [LINE])
        self.assertEqual(png_size(path), tuple(cmd.get_viewport()))

    def test_mpng_once(self):
        cmd.mset('1x3')
        prefix = self.path('frame')
        self.assertEqual(self.lines(lambda: cmd.mpng(
            prefix, mode=2, width=24, height=18)), [LINE])
        frames = sorted(glob.glob(prefix + '*.png'))
        self.assertEqual(len(frames), 3)
        for frame in frames:
            self.assertEqual(png_size(frame), (24, 18))

    @unittest.skipIf(shutil.which('true') is None, 'no `true` on PATH')
    def test_povray_immediate(self):
        # POV-Ray immediate mode: render_from_string shells out to
        # povray_exe; `true` stands in, so no image comes back.
        import pymol.povray
        saved = pymol.povray.povray_exe
        pymol.povray.povray_exe = 'true'
        cmd.set('batch_prefix', self.path('pov'))
        try:
            lines = self.lines(lambda: cmd.ray(24, 18, renderer=1))
        finally:
            pymol.povray.povray_exe = saved
        self.assertEqual(lines, [LINE])
        self.assertTrue(os.path.exists(self.path('pov.pov')))


class TestNoticeSilent(NoticeCase):
    """Never otherwise: no rig, rig off or empty, or nothing CPU-traced."""

    def traces(self):
        return [
            ('ray', lambda: cmd.ray(24, 18)),
            ('png', lambda: cmd.png(self.path('a.png'), 24, 18, ray=1)),
            ('mpng', lambda: cmd.mpng(self.path('f'), mode=2, width=24,
                                      height=18)),
        ]

    @testing.foreach('none', 'off', 'empty')
    def test_rig_not_on(self, label):
        cmd.set_lights(NOT_ON[label])
        cmd.mset('1x2')
        for name, func in self.traces():
            self.assertEqual(self.lines(func), [], '%s, %s' % (label, name))

    def test_switched_off_live(self):
        cmd.set_lights(RIG_ON)
        lighting._light_set(-1, 'enabled', 0)
        self.assertEqual(self.lines(lambda: cmd.ray(24, 18)), [])

    # Rig on, but nothing traced. Order matters: the rig is set BEFORE the
    # `ray` (setting it afterwards would invalidate the copy, see
    # test_rig_change_retraces), and only the `png` is captured.

    def test_prior_image(self):
        cmd.set_lights(RIG_ON)
        cmd.ray(24, 18)
        path = self.path('prior.png')
        self.assertEqual(self.lines(lambda: cmd.png(path, prior=1)), [])
        self.assertEqual(png_size(path), (24, 18))

    @unittest.skipUnless(HEADLESS, 'headless only: png writes the copy')
    def test_copy(self):
        cmd.set_lights(RIG_ON)
        cmd.ray(24, 18)
        path = self.path('copy.png')
        self.assertEqual(self.lines(lambda: cmd.png(path)), [])
        self.assertEqual(png_size(path), (24, 18))

    def test_geometry_test_mode(self):
        # renderer 2 tests the geometry and makes no image.
        cmd.set_lights(RIG_ON)
        self.assertEqual(self.lines(lambda: cmd.ray(24, 18, renderer=2)), [])

    def test_warnings_disabled(self):
        # Real PyMOL feedback: `feedback disable, ray, warnings` silences it.
        cmd.set_lights(RIG_ON)
        cmd.feedback('disable', 'ray', 'warnings')
        self.assertEqual(self.lines(lambda: cmd.ray(24, 18)), [])


class TestCpuImageUnchanged(NoticeCase):
    """The CPU tracer never reads the rig: its image is byte-identical with
    no rig, with the rig on (ambient 0.6, classic 0, coloured and shadowed
    lights, haze) and with the rig off."""

    def trace(self):
        data = cmd.png(None, 64, 48, ray=1)
        with Image.open(io.BytesIO(data)) as img:
            return np.asarray(img.convert('RGBA')).astype(np.int16)

    def test_byte_identical(self):
        cmd.bg_color('white')
        # Throwaway: lazy rep builds cannot differ between compared renders.
        self.trace()
        base = self.trace()
        self.assertEqual(base.shape, (48, 64, 4))
        # The peptide is in the image, so the comparison means something.
        self.assertGreater(int((base != base[0, 0]).any(axis=-1).sum()), 50)

        for label, rig in (('on', RIG_ON), ('off', RIG_OFF), ('none', None)):
            cmd.set_lights(rig)
            out = {}

            def run():
                out['img'] = self.trace()
            lines = self.lines(run)
            self.assertEqual(lines, [LINE] if rig is RIG_ON else [], label)
            diff = int(np.abs(out['img'] - base).max())
            self.assertEqual(diff, 0, '%s: max pixel difference %d'
                             % (label, diff))


def claim_main_thread(testcase):
    """Make the calling thread pass for the app's main thread, so
    run_on_main runs the tool body inline (headless, nothing drains its
    queue). Restores the process-global _main_ident afterwards. Copied from
    test_mcp_tools.py."""
    testcase.addCleanup(setattr, mainthread, '_main_ident',
                        mainthread._main_ident)
    mainthread.drain_main_thread_queue()


class TestMcpCapture(NoticeCase):
    """MCP capture_viewport traces on the CPU (cmd.png ray=1). The image stays
    first (clients read content[0]); while the rig is on, a text note with
    the notice follows it, read in the same main-thread call."""

    NOTE = {'type': 'text', 'text': 'Note: ' + NOTICE}

    def setUp(self):
        super().setUp()
        claim_main_thread(self)

    def capture(self):
        """Run the tool; check it succeeded with a 24 x 18 PNG first."""
        out = {}

        def run():
            out['result'] = tools._capture_viewport(
                {'width': 24, 'height': 18})
        self.console = self.lines(run)
        result = out['result']
        self.assertIs(result['isError'], False, result)
        content = result['content']
        image = content[0]
        self.assertEqual(image['type'], 'image')
        self.assertEqual(image['mimeType'], 'image/png')
        data = base64.b64decode(image['data'])
        self.assertEqual(data[:8], PNG_MAGIC)
        with Image.open(io.BytesIO(data)) as img:
            self.assertEqual(img.size, (24, 18))
        return content

    @testing.foreach('none', 'off', 'empty')
    def test_no_note(self, label):
        cmd.set_lights(NOT_ON[label])
        content = self.capture()
        self.assertEqual([item['type'] for item in content], ['image'], label)
        self.assertEqual(self.console, [], label)

    def test_note_with_rig_on(self):
        cmd.set_lights(RIG_ON)
        content = self.capture()
        self.assertEqual(len(content), 2)
        self.assertEqual(content[1], self.NOTE)
        # The console line still prints, once (CmdPNG), not once more.
        self.assertEqual(self.console, [LINE])

    def test_note_follows_the_rig(self):
        cmd.set_lights(RIG_ON)
        self.assertEqual(self.capture()[1:], [self.NOTE])
        lighting._light_set(-1, 'enabled', 0)
        self.assertEqual(self.capture()[1:], [])

    def test_description(self):
        tool = next(t for t in tools.TOOLS if t['name'] == 'capture_viewport')
        description = tool['description']
        self.assertIn('Metal', description)
        self.assertIn("PyMOL's lights", description)
        self.assertIn('set_lights', description)


class TestDocs(testing.PyMOLTestCase):
    """`help ray`, `help png` and `help mpng` state the policy: the CPU
    tracer keeps PyMOL's own lights; studio lighting is Metal-only."""

    @testing.foreach('ray', 'png', 'mpng')
    def test_policy_note(self, name):
        doc = ' '.join(getattr(cmd, name).__doc__.split())
        self.assertIn('Metal renderer', doc, name)
        self.assertIn("PyMOL's own lights", doc, name)
        self.assertIn('see "get_lights"', doc, name)
        self.assertIn('A notice says so once per command.', doc, name)
