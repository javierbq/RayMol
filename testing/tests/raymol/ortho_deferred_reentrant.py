"""A deferred job may queue another one while the queue drains. In the app,
`png` with a size defers OrthoDeferImage's job, which calls SceneDeferImage,
and that queues the render again when there is still no valid GL context
(a `refresh` from a script). OrthoExecDeferred ran the queue with a range-for
over the vector the push went into, then cleared it: the new job was cleared
without ever running, and when the push reallocated the vector the loop went
on through the freed buffer (std::bad_function_call, or a fault under Guard
Malloc). It now runs the jobs it took and leaves new ones for the next drain.

Headless, the way to run code inside a job is cmd.raw_image_callback, which
the job `draw` queues calls; here it stores scenes, which queues each one's
thumbnail render.

Every case runs in a child pymol: deferred jobs run headless only after
_cmd._idle, which cannot be undone for the process, and the old core aborts
the process. The Guard Malloc subtest skips where it cannot load, for example
under a hardened-runtime interpreter that drops DYLD_INSERT_LIBRARIES; with
RAYMOL_REQUIRE_GMALLOC=1 (set in CI) it fails instead.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run tests/raymol/ortho_deferred_reentrant.py
"""
import json
import os
import subprocess
import sys
import textwrap

from pymol import testing

GMALLOC = '/usr/lib/libgmalloc.dylib'

CHILD = textwrap.dedent('''
    import json
    import sys
    from pymol import cmd, _cmd

    # MovieScene::THUMBNAIL_WIDTH x THUMBNAIL_HEIGHT, RGBA: the zero-filled
    # thumbnail `scene store` leaves until its render replaces it
    UNRENDERED = 220 * 124 * 4

    # ExecutiveDrawNow runs deferred jobs only once PyMOL is "idle and ready"
    for _ in range(3):
        _cmd._idle(cmd._COb)

    def drain():
        # The draw job hands the callback the scene's current image, which a
        # headless draw never makes, so ray one; `refresh` would drop it again
        # before draining. _cmd._draw drains the queue as a host's frame does.
        cmd.ray(32, 24)
        _cmd._draw(cmd._COb)

    def report():
        return {
            'waiting': bool(_cmd.wait_deferred(cmd._COb)),
            'calls': calls,
            'unrendered': sorted(
                name for name in cmd.get_scene_list()
                if len(cmd.get_scene_thumbnail(name)) == UNRENDERED),
        }

    queued_in_job, queued_before = map(int, sys.argv[-2:])
    calls = 0

    def callback(image):
        global calls
        calls += 1
        if calls == 1:
            for i in range(queued_in_job):
                cmd.scene('in_job_%d' % i, 'store')

    cmd.fragment('ala')
    cmd.raw_image_callback = callback
    cmd.draw(32, 24)
    for i in range(queued_before):
        cmd.scene('before_%d' % i, 'store')
    drain()
    first = report()
    drain()
    print('RESULT ' + json.dumps([first, report()]))
''')

IN_JOB = ['in_job_%d' % i for i in range(8)]


class TestJobQueuedWhileTheQueueDrains(testing.PyMOLTestCase):

    def runChild(self, queued_in_job, queued_before, env=None):
        """Return the child's stderr and [state after the first drain, state
        after the second]."""
        with testing.mktemp('.py') as script:
            with open(script, 'w') as handle:
                handle.write(CHILD)
            proc = subprocess.run(
                [sys.executable, '-m', 'pymol', '-ckq', script, '--',
                 str(queued_in_job), str(queued_before)],
                env=env, capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0,
                         'exit %d\n%s' % (proc.returncode, proc.stderr[-2000:]))
        lines = [line for line in proc.stdout.splitlines()
                 if line.startswith('RESULT ')]
        self.assertEqual(len(lines), 1, proc.stdout[-2000:])
        return proc.stderr, json.loads(lines[0][len('RESULT '):])

    def testAJobQueuedByAJobRunsAtTheNextDrain(self):
        _, (first, second) = self.runChild(1, 0)
        self.assertEqual(first, {'waiting': True, 'calls': 1,
                                 'unrendered': ['in_job_0']},
                         'the job queued during the drain should wait for '
                         'the next one, not be dropped')
        self.assertEqual(second, {'waiting': False, 'calls': 1,
                                  'unrendered': []})

    # Two jobs, so the loop has one left to run after the pushes reallocate
    # the queue: the old loop read it from the freed buffer.
    GROWN_FIRST = {'waiting': True, 'calls': 1, 'unrendered': IN_JOB}
    GROWN_SECOND = {'waiting': False, 'calls': 1, 'unrendered': []}

    def testTheQueueGrowingDuringADrain(self):
        _, (first, second) = self.runChild(8, 1)
        self.assertEqual(first, self.GROWN_FIRST)
        self.assertEqual(second, self.GROWN_SECOND)

    def guardMallocUnavailable(self, reason):
        """Skip, or fail where Guard Malloc must work."""
        if os.environ.get('RAYMOL_REQUIRE_GMALLOC') == '1':
            self.fail(reason + ', and RAYMOL_REQUIRE_GMALLOC=1 requires it')
        self.skipTest(reason)

    def testTheQueueGrowingDuringADrainUnderGuardMalloc(self):
        # Guard Malloc unmaps freed memory, so the old loop faults on its
        # first read of the freed buffer instead of depending on what the
        # allocator left there.
        if sys.platform != 'darwin' or not os.path.exists(GMALLOC):
            self.guardMallocUnavailable('needs macOS Guard Malloc, ' + GMALLOC)
        # the interpreter itself, not a shell launcher: SIP strips DYLD_*
        # variables when a protected binary such as /bin/sh starts
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=GMALLOC)
        stderr, (first, second) = self.runChild(8, 1, env)
        if 'GuardMalloc' not in stderr:
            self.guardMallocUnavailable(
                'Guard Malloc did not load in %s (a hardened-runtime '
                'interpreter drops DYLD_INSERT_LIBRARIES)' % sys.executable)
        self.assertEqual(first, self.GROWN_FIRST)
        self.assertEqual(second, self.GROWN_SECOND)
