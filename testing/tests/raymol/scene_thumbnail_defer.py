"""A scene's thumbnail render waits for the next draw when PyMOL has no valid
GL context: headless (the next refresh), or in the app (the next frame). By
then reinitialize, a session load or scene delete/clear/rename may have freed
the scene. The render used to write through a pointer into that freed scene
(MovieSceneStore -> SceneDeferImage(..., &scene.thumbnail)), so a later
refresh aborted with "pointer being freed was not allocated" in the
SceneDeferImage lambda -- or silently corrupted the heap, depending on what
had reused the memory. It now finds the scene by name when it runs.

Only the Guard Malloc subtests catch that bug: a write into a freed scene
usually lands harmlessly in a normal heap, so the in-process subtests passed
on the unfixed core too. They check what the fix promises (the refresh
survives, the queue empties, a renamed scene keeps its blank thumbnail), not
the use-after-free. The Guard Malloc subtests skip where it cannot load, for
example under a hardened-runtime interpreter that drops DYLD_INSERT_LIBRARIES;
with RAYMOL_REQUIRE_GMALLOC=1 (set in CI) they fail instead, so the file
cannot stop guarding against the bug unnoticed.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run tests/raymol/scene_thumbnail_defer.py
"""
import os
import subprocess
import sys
import textwrap

from pymol import cmd, _cmd, testing

# MovieScene::THUMBNAIL_WIDTH x THUMBNAIL_HEIGHT, RGBA: the zero-filled
# thumbnail `scene store` leaves until the render replaces it
UNRENDERED = 220 * 124 * 4

GMALLOC = '/usr/lib/libgmalloc.dylib'

FREES = ('reinitialize', 'delete', 'clear', 'rename', 'load')


def run_deferred_jobs_at_refresh():
    """ExecutiveDrawNow runs deferred jobs only once PyMOL is "idle and
    ready": three PyMOL_Idle calls after a draw. Nothing idles while a
    `pymol -c` script runs, so idle by hand. One-way for the process."""
    for _ in range(3):
        _cmd._idle(cmd._COb)


def free_scenes(how, names, filename):
    if how == 'reinitialize':
        cmd.reinitialize()
    elif how == 'delete':
        for name in names:
            cmd.scene(name, 'delete')
    elif how == 'clear':
        cmd.scene('*', 'clear')
    elif how == 'rename':
        for name in names:
            cmd.scene(name, 'rename', new_key=name + '_renamed')
    elif how == 'load':
        cmd.save(filename)
        cmd.load(filename)


# The same steps in a child process under Guard Malloc, where a freed
# scene's memory is unmapped: the old code faults on the first stale render.
CHILD = textwrap.dedent('''
    import sys
    from pymol import cmd, _cmd
    for _ in range(3):
        _cmd._idle(cmd._COb)
    cmd.fragment('ala')
    cmd.scene('A', 'store')
    assert _cmd.wait_deferred(cmd._COb)
    how, filename = sys.argv[-2:]
    if how == 'reinitialize':
        cmd.reinitialize()
    elif how == 'delete':
        cmd.scene('A', 'delete')
    elif how == 'clear':
        cmd.scene('*', 'clear')
    elif how == 'rename':
        cmd.scene('A', 'rename', new_key='B')
    elif how == 'load':
        cmd.save(filename)
        cmd.load(filename)
    assert _cmd.wait_deferred(cmd._COb)
    cmd.refresh()
    print('REFRESHED')
''')


class TestDeferredSceneThumbnail(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        run_deferred_jobs_at_refresh()
        cmd.fragment('ala')

    def storePending(self, name):
        cmd.scene(name, 'store')
        self.assertTrue(_cmd.wait_deferred(cmd._COb),
                        'the thumbnail render should wait for a draw')
        self.assertEqual(len(cmd.get_scene_thumbnail(name)), UNRENDERED)

    def testRenderLandsInTheStoredScene(self):
        self.storePending('A')
        cmd.refresh()
        self.assertFalse(_cmd.wait_deferred(cmd._COb))
        self.assertNotEqual(len(cmd.get_scene_thumbnail('A')), UNRENDERED)

    @testing.foreach(*FREES)
    def testSceneFreedBeforeTheRender(self, how):
        # Survives, drains the queue, keeps a renamed scene's thumbnail. It
        # does not catch a write into the freed scene by itself (see the
        # module docstring): the Guard Malloc variant below does.
        # many stale renders: more chances to hit reused memory without the fix
        names = ['S%d' % i for i in range(20)]
        for name in names:
            self.storePending(name)
        with testing.mktemp('.pse') as filename:
            free_scenes(how, names, filename)
            self.assertTrue(_cmd.wait_deferred(cmd._COb))
            cmd.fragment('gly')     # allocations that may reuse the freed scenes
            cmd.refresh()
        self.assertFalse(_cmd.wait_deferred(cmd._COb))
        if how == 'rename':
            # the render was for the old name: it is dropped, and the renamed
            # scene keeps the thumbnail it had
            for name in names:
                self.assertEqual(len(cmd.get_scene_thumbnail(name + '_renamed')),
                                 UNRENDERED)

    def guardMallocUnavailable(self, reason):
        """Skip, or fail where Guard Malloc must work: without it nothing in
        this file catches the use-after-free."""
        if os.environ.get('RAYMOL_REQUIRE_GMALLOC') == '1':
            self.fail(reason + ', and RAYMOL_REQUIRE_GMALLOC=1 requires it')
        self.skipTest(reason)

    @testing.foreach(*FREES)
    def testSceneFreedBeforeTheRenderUnderGuardMalloc(self, how):
        if sys.platform != 'darwin' or not os.path.exists(GMALLOC):
            self.guardMallocUnavailable('needs macOS Guard Malloc, ' + GMALLOC)
        with testing.mktemp('.py') as script, testing.mktemp('.pse') as pse:
            with open(script, 'w') as handle:
                handle.write(CHILD)
            # the interpreter itself, not a shell launcher: SIP strips DYLD_*
            # variables when a protected binary such as /bin/sh starts
            env = dict(os.environ, DYLD_INSERT_LIBRARIES=GMALLOC)
            proc = subprocess.run(
                [sys.executable, '-m', 'pymol', '-ckq', script, '--', how, pse],
                env=env, capture_output=True, text=True, timeout=300)
        if 'GuardMalloc' not in proc.stderr + proc.stdout:
            self.guardMallocUnavailable(
                'Guard Malloc did not load in %s (a hardened-runtime '
                'interpreter drops DYLD_INSERT_LIBRARIES)' % sys.executable)
        self.assertEqual(proc.returncode, 0,
                         '%s: exit %d\n%s' % (how, proc.returncode, proc.stderr[-2000:]))
        self.assertIn('REFRESHED', proc.stdout)
