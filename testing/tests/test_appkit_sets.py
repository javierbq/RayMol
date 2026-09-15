"""Tests for pymol.appkit_sets -- the SETS: change marker and the drawer helpers (#417).

The object panel's 500 ms poll must not grow with the number of entries in a set
(#271, #398, #421), so set contents never travel over the feedback channel: Swift
reads the .raymol file itself and re-reads only when the marker's version changes.
These tests pin the marker's contract -- what it carries, when it is (and is not)
printed, that polling never creates a working file, that it stays under PyMOL's
1024-byte feedback-line cap -- and the helpers the drawer calls.

    pymol -ckqy testing/testing.py --run testing/tests/test_appkit_sets.py
"""
import tempfile
import contextlib
import io
import json
import os
import struct
import sys
import types

from pymol import cmd, testing
from pymol import appkit_sets
from pymol.metrics import binding as mbinding, schema as mschema, store as mstore
from pymol.sets import binding, store

# layer0/PyMOLGlobals.h: OrthoLineLength -- the per-line feedback cap.
ORTHO_LINE_LENGTH = 1024

TOOL = 'setsuitest'
BATCH_MODULE = 'pymol.sets.batch'


@contextlib.contextmanager
def captured():
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        yield buf


def markers(text):
    """The SETS: payloads among the captured lines, decoded, in order."""
    out = []
    for line in text.splitlines():
        if line.startswith(appkit_sets.MARKER_PREFIX):
            out.append(json.loads(line[len(appkit_sets.MARKER_PREFIX):]))
    return out


class AppkitSetsTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved_schemas = dict(mschema._SCHEMAS)
        # Every test gets its own $RAYMOL_SETS_DIR (#447 review): the working
        # container -- and anything preserved from it -- otherwise lands in the real
        # $TMPDIR, where it accumulates a few MB per run and where the retention sweep
        # would take a CLI user's own recovered sessions with it.
        self._sets_dir = tempfile.mkdtemp(prefix='raymol_sets_dir_')
        self._had_sets_dir = os.environ.get('RAYMOL_SETS_DIR')
        os.environ['RAYMOL_SETS_DIR'] = self._sets_dir
        mschema.register(TOOL, [
            mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100, higher_is_better=True),
            mschema.MetricSpec('rmsd', mschema.STATE, lo=0, hi=10, units='A'),
        ], replace=True)
        # The module keeps the last marker and the drawer ids; every test starts from
        # "nothing printed yet, nothing open, nothing peeked".
        self._had_batch = sys.modules.get(BATCH_MODULE)
        sys.modules.pop(BATCH_MODULE, None)
        # ... and the PACKAGE ATTRIBUTE, which `from pymol.sets import batch` prefers
        # over sys.modules. Without this, the first test in the process to call the
        # real module leaves `pymol.sets.batch` bound, and every install_fake_batch
        # after it is silently ignored -- the tests below then assert against an empty
        # progress table and fail in file order rather than on their own merits.
        import pymol.sets as _sets_pkg
        self._had_batch_attr = getattr(_sets_pkg, 'batch', None)
        if self._had_batch_attr is not None:
            delattr(_sets_pkg, 'batch')
        store.reset()
        appkit_sets.close_set()
        appkit_sets.reset_marker()

    def tearDown(self):
        binding.clear_peek()
        appkit_sets.close_set()
        appkit_sets.reset_marker()
        store.reset()
        mstore.clear()
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._saved_schemas)
        # A fake batch module must not leak into the next test FILE: the CI job runs
        # every file in one process.
        if self._had_batch is not None:
            sys.modules[BATCH_MODULE] = self._had_batch
        else:
            sys.modules.pop(BATCH_MODULE, None)
        import pymol.sets as _sets_pkg
        if self._had_batch_attr is not None:
            _sets_pkg.batch = self._had_batch_attr
        elif getattr(_sets_pkg, 'batch', None) is not None:
            delattr(_sets_pkg, 'batch')
        testing.PyMOLTestCase.tearDown(self)
        # Last, so PyMOLTestCase's own reinitialize still resets the store with the
        # private $RAYMOL_SETS_DIR in place.
        if self._had_sets_dir is None:
            os.environ.pop('RAYMOL_SETS_DIR', None)
        else:
            os.environ['RAYMOL_SETS_DIR'] = self._had_sets_dir
        __import__('shutil').rmtree(self._sets_dir, ignore_errors=True)

    # -- fixtures --------------------------------------------------------------------

    def peptide(self, name, score=50.0, rmsd=1.0):
        cmd.fab('ACDEF', name, chain='A')
        mbinding.record(name, TOOL, [
            mstore.value(TOOL, 'score', value=score),
            mstore.value(TOOL, 'rmsd', value=rmsd, state=1),
        ], inputs={'seed': 1}, tool_version='t1')
        return name

    def populated(self, n=3, name='s'):
        cmd.set_create(name)
        for i in range(n):
            self.peptide('p%d' % i, score=10.0 * (i + 1), rmsd=0.5 * (i + 1))
            cmd.set_add(name, 'p%d' % i)
            cmd.delete('p%d' % i)
        mstore.clear()
        return name

    def entry(self, set_name, entry_name):
        return store.active().entry(store.active().get_set(set_name)['id'], entry_name)

    def install_fake_batch(self, table):
        mod = types.ModuleType(BATCH_MODULE)
        mod.running = lambda set_id=None: table
        sys.modules[BATCH_MODULE] = mod
        return mod


class TestMarker(AppkitSetsTestCase):

    def test_idle_marker_is_empty_and_opens_nothing(self):
        # A fresh process with no set has no container. Polling must report that
        # WITHOUT opening the pid-scoped working file -- store.active() would create
        # it, and a file per launch that never touched a set is exactly the side
        # effect the store's is_open() exists to avoid.
        self.assertFalse(store.is_open())
        with captured() as out:
            appkit_sets.poll()
        found = markers(out.getvalue())
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0], {'v': 0, 'path': '', 'active': '', 'peek': '',
                                    'running': {}})
        self.assertFalse(store.is_open(), 'poll() must never open a container')

    def test_marker_prints_only_on_change(self):
        with captured() as out:
            appkit_sets.poll()
            appkit_sets.poll()
            appkit_sets.poll()
        self.assertEqual(len(markers(out.getvalue())), 1,
                         'an unchanged state must not be re-sent every tick')

    def test_version_and_path_follow_the_container(self):
        with captured():
            appkit_sets.poll()
        self.populated(2)
        c = store.active()
        with captured() as out:
            appkit_sets.poll()
        found = markers(out.getvalue())
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]['path'], c.path)
        self.assertEqual(found[0]['v'], c.version())
        self.assertGreater(found[0]['v'], 0)
        # A write bumps the version and so re-emits; nothing else changed.
        cmd.set_star('s', 'p0')
        with captured() as out:
            appkit_sets.poll()
        again = markers(out.getvalue())
        self.assertEqual(len(again), 1)
        self.assertGreater(again[0]['v'], found[0]['v'])
        self.assertEqual(again[0]['path'], c.path)

    def test_read_does_not_bump(self):
        self.populated(1)
        with captured():
            appkit_sets.poll()
        cmd.set_list('s')
        cmd.set_info('s')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue()), [],
                         'a read-only command must not look like a change')

    def test_reset_clears_everything(self):
        self.populated(1)
        appkit_sets.open_set('s')
        with captured():
            appkit_sets.poll()
        store.reset()      # what `load x.pse` and `reinitialize` do
        with captured() as out:
            appkit_sets.poll()
        found = markers(out.getvalue())
        self.assertEqual(found, [{'v': 0, 'path': '', 'active': '', 'peek': '',
                                  'running': {}}])

    def _fake_batches(self, n):
        self.install_fake_batch({
            ('%08x' % i): {'done': i, 'total': 1000, 'tool': 'binder_design'}
            for i in range(n)})

    def test_marker_keeps_the_ids_when_only_the_counts_must_go(self):
        # The COUNTS go first, not the sets: the badge must still appear on the
        # right rows saying "a batch is running", because a vanished badge reads as
        # "the batch finished".
        #
        # The truncated form is a LIST of ids for a measured reason. Carrying
        # {"id": {"done": 0, "total": 0, "tool": ""}} instead costs ~41 bytes a
        # batch and crosses the cap at about twenty, so the stage fell through to
        # "drop everything" exactly when it was needed; a bare id costs ~11.
        self.populated(1)
        appkit_sets.open_set('s')
        appkit_sets.peek('s', 'p0')
        self._fake_batches(40)
        text = appkit_sets.marker()
        self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH)
        payload = json.loads(text[len(appkit_sets.MARKER_PREFIX):])
        self.assertEqual(payload['trunc'], 1)
        self.assertIsInstance(payload['running'], list)
        self.assertEqual(len(payload['running']), 40)
        self.assertEqual(payload['running'], sorted('%08x' % i for i in range(40)))
        self.assertTrue(payload['path'])
        self.assertTrue(payload['active'])
        self.assertTrue(payload['peek'])

    def test_the_ids_stage_is_reached_before_the_cap_not_after(self):
        # The regression this pins: the truncated form has to be small enough that
        # a realistic number of concurrent batches actually reaches it. At 20 and
        # at 60 the ids must survive -- the previous encoding lost them at both.
        self.populated(1)
        appkit_sets.open_set('s')
        for n in (20, 60):
            self._fake_batches(n)
            payload = json.loads(appkit_sets.marker()[len(appkit_sets.MARKER_PREFIX):])
            self.assertEqual(len(payload['running']), n,
                             'the ids must survive at %d batches' % n)
            self.assertEqual(payload['trunc'], 1)

    def test_marker_drops_running_entirely_when_even_the_ids_do_not_fit(self):
        # Last stage: hundreds of concurrent batches, where even bare ids are
        # thousands of bytes. The fields the drawer cannot work without survive.
        self.populated(1)
        appkit_sets.open_set('s')
        self._fake_batches(400)
        text = appkit_sets.marker()
        self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH)
        payload = json.loads(text[len(appkit_sets.MARKER_PREFIX):])
        self.assertEqual(payload['running'], [])
        self.assertEqual(payload['trunc'], 1)
        self.assertTrue(payload['path'])
        self.assertTrue(payload['active'])

    def test_every_stage_stays_under_the_cap(self):
        # Whatever the batch count, the line must never split -- that is the whole
        # reason the ladder exists.
        self.populated(1)
        appkit_sets.open_set('s')
        for n in (0, 1, 19, 20, 40, 68, 69, 70, 200, 400, 2000):
            self._fake_batches(n)
            text = appkit_sets.marker()
            self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH,
                            '%d batches produced a %d-byte marker' % (n, len(text)))

    def test_untruncated_marker_carries_no_trunc_flag(self):
        self.populated(1)
        self.install_fake_batch({'ab12cd34': {'done': 3, 'total': 10, 'tool': 'rfd3'}})
        payload = json.loads(appkit_sets.marker()[len(appkit_sets.MARKER_PREFIX):])
        self.assertNotIn('trunc', payload)
        self.assertEqual(payload['running']['ab12cd34']['done'], 3)


class TestRunning(AppkitSetsTestCase):

    def test_running_is_empty_when_batch_module_is_absent(self):
        # #416 provides pymol.sets.batch; on a build without it the marker must still
        # be complete and well-formed, with `running` == {}.
        self.assertNotIn(BATCH_MODULE, sys.modules)
        self.populated(1)
        state = appkit_sets.state()
        self.assertEqual(state['running'], {})
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['running'], {})

    def test_running_is_forwarded_when_present(self):
        self.populated(1)
        set_id = store.active().get_set('s')['id']
        self.install_fake_batch({set_id: {'done': 3, 'total': 10, 'tool': 'rfd3'}})
        with captured() as out:
            appkit_sets.poll()
        found = markers(out.getvalue())
        self.assertEqual(found[0]['running'],
                         {set_id: {'done': 3, 'total': 10, 'tool': 'rfd3'}})

    def test_progress_change_reemits(self):
        self.populated(1)
        set_id = store.active().get_set('s')['id']
        table = {set_id: {'done': 1, 'total': 10, 'tool': 'rfd3'}}
        self.install_fake_batch(table)
        with captured():
            appkit_sets.poll()
        table[set_id]['done'] = 2
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['running'][set_id]['done'], 2)

    def test_broken_batch_module_is_tolerated(self):
        self.populated(1)
        mod = types.ModuleType(BATCH_MODULE)

        def boom(set_id=None):
            raise RuntimeError('progress table exploded')
        mod.running = boom
        sys.modules[BATCH_MODULE] = mod
        self.assertEqual(appkit_sets.state()['running'], {})
        mod.running = lambda set_id=None: 'not a dict'
        self.assertEqual(appkit_sets.state()['running'], {})
        mod.running = lambda set_id=None: {'x': {'done': 'many', 'total': 1, 'tool': 't'}}
        self.assertEqual(appkit_sets.state()['running'], {})


class TestDrawerHelpers(AppkitSetsTestCase):

    def test_open_and_close_set(self):
        self.populated(1)
        set_id = store.active().get_set('s')['id']
        with captured():
            appkit_sets.poll()
        self.assertEqual(appkit_sets.open_set('s'), set_id)
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['active'], set_id)
        appkit_sets.close_set()
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['active'], '')

    def test_open_unknown_set_raises(self):
        self.populated(1)
        from pymol.sets.errors import SetNotFound
        with self.assertRaises(SetNotFound):
            appkit_sets.open_set('nope')

    def test_active_follows_set_delete(self):
        self.populated(1)
        appkit_sets.open_set('s')
        with captured():
            appkit_sets.poll()
        cmd.set_delete('s')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['active'], '',
                         'the drawer must not stay open on a set that is gone')

    def test_peek_marks_the_entry_and_draws_it(self):
        self.populated(2)
        e = self.entry('s', 'p1')
        with captured():
            appkit_sets.poll()
        self.assertEqual(appkit_sets.peek('s', 'p1'), e['id'])
        self.assertIn(binding.PEEK, cmd.get_names('all'))
        self.assertGreater(cmd.count_atoms(binding.PEEK), 0)
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['peek'], e['id'])
        appkit_sets.clear_peek()
        self.assertNotIn(binding.PEEK, cmd.get_names('all'))
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['peek'], '')

    def test_console_clear_is_reflected(self):
        # `set_peek` with no arguments from the console (or over MCP) clears the peek
        # object behind the drawer's back; the marker must notice on the next poll.
        self.populated(1)
        appkit_sets.peek('s', 'p0')
        with captured():
            appkit_sets.poll()
        cmd.set_peek()
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['peek'], '')

    def test_a_console_peek_of_another_entry_drops_the_mark(self):
        # `set_peek s, e` from the console or MCP replaces the peek object behind
        # the drawer's back. Before the stamp, `state()` only checked that SOME
        # peek object existed, so the drawer kept ◐ on the PREVIOUSLY peeked row --
        # a mark pointing at an entry that is not the one on screen.
        self.populated(3)
        first = self.entry('s', 'p0')['id']
        appkit_sets.peek('s', 'p0')
        self.assertEqual(appkit_sets.state()['peek'], first)
        cmd.set_peek('s', 'p1')          # the console's own path, not ours
        self.assertIn(binding.PEEK, cmd.get_names('all'))
        self.assertEqual(appkit_sets.state()['peek'], '',
                         'the mark must not stay on the row that is no longer peeked')

    def test_our_own_peek_survives_repeated_polls(self):
        # The stamp must not be so eager that it clears a peek nothing touched.
        self.populated(2)
        wanted = self.entry('s', 'p1')['id']
        appkit_sets.peek('s', 'p1')
        for _ in range(3):
            self.assertEqual(appkit_sets.state()['peek'], wanted)

    def test_toggle_stage_round_trip(self):
        self.populated(2)
        names = appkit_sets.toggle_stage('s', 'p0')
        self.assertEqual(names, ['p0'])
        self.assertIn('p0', cmd.get_names('public_objects'))
        self.assertTrue(self.entry('s', 'p0')['staged_object'])
        removed = appkit_sets.toggle_stage('s', 'p0')
        self.assertEqual(removed, ['p0'])
        self.assertNotIn('p0', cmd.get_names('public_objects'))
        self.assertFalse(self.entry('s', 'p0')['staged_object'])

    def test_toggle_stage_over_budget_warns_instead_of_raising(self):
        self.populated(3)
        cmd.set_budget(1, 's')
        appkit_sets.toggle_stage('s', 'p0')
        with captured() as out:
            names = appkit_sets.toggle_stage('s', 'p1')
        self.assertEqual(names, [])
        self.assertIn('budget', out.getvalue())
        self.assertNotIn('p1', cmd.get_names('public_objects'))
        self.assertIn('p0', cmd.get_names('public_objects'))

    def test_toggle_stage_mixed_selection_stages_the_rest(self):
        self.populated(3)
        appkit_sets.toggle_stage('s', 'p0')
        appkit_sets.toggle_stage('s', 'p0+p1')
        self.assertIn('p0', cmd.get_names('public_objects'))
        self.assertIn('p1', cmd.get_names('public_objects'))


class TestSchemaContract(AppkitSetsTestCase):
    """The names the Swift reader (SetsStore.swift) selects by.

    That reader opens the same file read-only and names these columns as string
    literals, so a rename in schema.py that misses it shows up as a silently EMPTY
    drawer. It cannot run Swift here; asserting the DDL still declares every name is
    the half of the contract this side can hold.
    """

    #: table -> columns SetsStore.swift selects. Keep in step with rows()/sets().
    SWIFT_READS = {
        'meta': ('key', 'value'),
        'sets': ('id', 'name', 'kind', 'tool', 'group_name', 'budget', 'ranking_key',
                 'sort_key', 'sort_desc', 'filter', 'columns', 'reference', 'created'),
        'entries': ('id', 'set_id', 'ord', 'name', 'starred', 'rejected', 'pinned',
                    'staged_object', 'n_chains', 'n_residues', 'tags', 'run_id'),
    }

    def test_ddl_declares_every_column_swift_selects(self):
        from pymol.sets import schema
        ddl = '\n'.join(schema.DDL)
        for table, columns in self.SWIFT_READS.items():
            self.assertIn('CREATE TABLE %s ' % table, ddl)
            for column in columns:
                self.assertIn(column, ddl,
                              '%s.%s is read by SetsStore.swift but is not in the DDL'
                              % (table, column))

    def test_metrics_table_and_entry_id_column_are_named_as_swift_expects(self):
        from pymol.sets import schema
        # SetsStore.rows() builds the join as m_<set_id> ... ON m.entry_id = e.id.
        self.assertEqual(schema.metrics_table('ab12cd34'), 'm_ab12cd34')
        self.populated(1)
        c = store.active()
        set_id = c.get_set('s')['id']
        columns = [r['name'] for r in
                   c._all('PRAGMA table_info(%s)' % schema.quote(schema.metrics_table(set_id)))]
        self.assertEqual(columns[0], 'entry_id')

    def test_columns_json_carries_the_metricspec_keys_swift_decodes(self):
        # MetricColumn decodes these names; `column` and `chain` are the two the
        # store adds to MetricSpec.as_dict() and Swift depends on both.
        self.populated(1)
        c = store.active()
        columns = c.columns(c.get_set('s')['id'])
        self.assertTrue(columns)
        for spec in columns:
            for key in ('key', 'scope', 'dtype', 'units', 'label', 'lo', 'hi',
                        'higher_is_better', 'chain', 'tool', 'column'):
                self.assertIn(key, spec)


class TestPollPanelHook(AppkitSetsTestCase):

    def test_poll_panel_emits_the_marker(self):
        # The one hook in appkit_inspector.poll_panel: the marker rides the same tick
        # as OBJPANEL:ready, so a set created from the console reaches the panel.
        from pymol import appkit_inspector
        self.populated(1)
        with captured() as out:
            appkit_inspector.poll_panel()
        text = out.getvalue()
        self.assertIn('OBJPANEL:ready', text)
        found = markers(text)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]['path'], store.active().path)


class TestRecovery(AppkitSetsTestCase):
    """The cold-launch recovery marker (#447).

    `SETSRECOVER:` is printed ONCE, at launch, not from the 500 ms poll: the question
    "did a previous RayMol leave sets behind" stats and opens files, and its answer
    cannot change while this process runs.
    """

    def setUp(self):
        AppkitSetsTestCase.setUp(self)    # $RAYMOL_SETS_DIR is this test's own
        self._had_swept = store._SWEPT
        self._had_own = store._OWN_RETIRED
        store._SWEPT = store._OWN_RETIRED = True

    def tearDown(self):
        store._SWEPT = self._had_swept
        store._OWN_RETIRED = self._had_own
        AppkitSetsTestCase.tearDown(self)

    def left_behind(self, entries=1, pid=999999):
        """A container a dead RayMol left with `entries` in it, already preserved."""
        path = os.path.join(store.working_dir(), 'raymol_sets_%d.raymol' % pid)
        c = store.Container(path)
        sid = c.create_set('left')['id']
        for i in range(entries):
            c.add_entry(sid, 'd%d' % i)
        c.close()
        return store.preserve_working_file(path)

    def payload(self, text):
        self.assertTrue(text.startswith(appkit_sets.RECOVER_PREFIX), text)
        return json.loads(text[len(appkit_sets.RECOVER_PREFIX):])

    def test_nothing_to_recover_is_still_an_answer(self):
        with captured() as out:
            appkit_sets.poll_recovery()
        payload = self.payload(out.getvalue().strip())
        self.assertEqual(payload, {'n': 0, 'files': []})
        self.assertFalse(store.is_open(), 'asking must not create a working file')

    def test_marker_reports_the_sets_and_entries_newest_first(self):
        older = self.left_behind(entries=2, pid=999999)
        newer = self.left_behind(entries=5, pid=999998)
        os.utime(older, (store._now() - 900, store._now() - 900))
        payload = self.payload(appkit_sets.recovery_marker())
        self.assertEqual(payload['n'], 2)
        self.assertEqual([f['path'] for f in payload['files']], [newer, older])
        self.assertEqual([f['entries'] for f in payload['files']], [5, 2])
        self.assertEqual([f['sets'] for f in payload['files']], [1, 1])
        self.assertEqual([f['session'] for f in payload['files']], [0, 0])

    def test_marker_names_a_few_files_but_always_counts_them_all(self):
        for i in range(appkit_sets.MAX_RECOVERABLE + 3):
            self.left_behind(pid=999000 + i)
        payload = self.payload(appkit_sets.recovery_marker())
        self.assertEqual(payload['n'], appkit_sets.MAX_RECOVERABLE + 3)
        self.assertEqual(len(payload['files']), appkit_sets.MAX_RECOVERABLE)

    def test_marker_stays_under_the_feedback_cap(self):
        # A pathological path: RayMolState is short, but RAYMOL_SETS_DIR is not ours.
        deep = os.path.join(self._sets_dir, 'd' * 120, 'e' * 120, 'f' * 120)
        os.makedirs(deep)
        os.environ['RAYMOL_SETS_DIR'] = deep
        for i in range(appkit_sets.MAX_RECOVERABLE):
            self.left_behind(pid=999000 + i)
        text = appkit_sets.recovery_marker()
        self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH)
        payload = self.payload(text)
        self.assertEqual(payload['n'], appkit_sets.MAX_RECOVERABLE,
                         'the count survives even when the files do not fit')
        self.assertLess(len(payload['files']), appkit_sets.MAX_RECOVERABLE,
                        'files are what gets dropped to fit')

    def test_the_500ms_poll_carries_no_recovery(self):
        self.left_behind()
        with captured() as out:
            appkit_sets.poll()
        self.assertNotIn(appkit_sets.RECOVER_PREFIX, out.getvalue())

    def test_discard_removes_the_container(self):
        path = self.left_behind()
        appkit_sets.discard_recovered(path)
        self.assertFalse(os.path.exists(path))
        self.assertEqual(appkit_sets.recoverable(), [])


def filter_markers(text):
    """How many `SETSFILTER:ready` lines the captured output holds."""
    return [line for line in text.splitlines()
            if line.startswith(appkit_sets.FILTER_PREFIX)]


def filter_channel():
    """The payload the filter channel currently holds, or None when it was never
    written. Read the way Swift reads it: a file in this process's TMPDIR."""
    from pymol import raymol_tmp
    path = raymol_tmp.channel_path(appkit_sets.FILTER_STEM)
    if not os.path.exists(path):
        return None
    with open(path) as handle:
        return json.load(handle)


def clear_filter_channel():
    from pymol import raymol_tmp
    try:
        os.unlink(raymol_tmp.channel_path(appkit_sets.FILTER_STEM))
    except OSError:
        pass


class FilterChannelTestCase(AppkitSetsTestCase):
    """The compiled-filter channel (#418).

    There is one filter grammar -- `pymol.sets.filter` -- and the drawer does not have a
    copy of it. It sends the expression here and gets back the COMPILED FRAGMENT, which
    it binds and runs against its own read-only connection. These tests pin both halves
    of that contract: that what comes back is what `filter.compile` produced, and that
    running it the way SetsStore.swift runs it selects exactly the rows `set_filter`
    counts.
    """

    def setUp(self):
        AppkitSetsTestCase.setUp(self)
        clear_filter_channel()

    def tearDown(self):
        clear_filter_channel()
        AppkitSetsTestCase.tearDown(self)

    def swift_names(self, set_name, payload):
        """The entry names Swift's row query returns for this payload.

        Reproduces SetsStore.rows() exactly: the same FROM, the same two aliases the
        fragment is written against, the fragment ANDed on and its params bound after
        the set id. If this ever disagrees with `n`, the drawer would be showing a
        different table from the one every set_* command acts on.
        """
        from pymol.sets import schema
        c = store.active()
        set_id = c.get_set(set_name)['id']
        sql = ('SELECT e.name FROM entries e LEFT JOIN %s m ON m.entry_id = e.id'
               ' WHERE e.set_id = ?' % schema.quote(schema.metrics_table(set_id)))
        if payload['sql']:
            sql += ' AND (%s)' % payload['sql']
        sql += ' ORDER BY e.ord'
        return [r[0] for r in c._conn.execute(sql, (set_id,) + tuple(payload['params']))]


class TestFilterChannel(FilterChannelTestCase):

    def test_preview_compiles_without_applying(self):
        self.populated(3)                          # scores 10, 20, 30
        appkit_sets.open_set('s')
        with captured() as out:
            payload = appkit_sets.preview_filter('s', 'score > 15')
        self.assertEqual(filter_markers(out.getvalue()),
                         [appkit_sets.FILTER_PREFIX + 'ready'])
        self.assertEqual(payload, filter_channel(), 'the file carries what we returned')
        self.assertEqual(payload['sql'], 'm."score" > ?')
        self.assertEqual(payload['params'], [15])
        self.assertEqual(payload['n'], 2)
        self.assertEqual(payload['total'], 3)
        self.assertEqual(payload['error'], '')
        self.assertEqual(payload['applied'], 0)
        self.assertEqual(store.active().get_set('s')['filter'], '',
                         'a preview must not become the set\'s filter')

    def test_the_fragment_selects_what_the_count_promises(self):
        self.populated(3)
        payload = appkit_sets.preview_filter('s', 'score >= 20 and score <= 30')
        self.assertEqual(self.swift_names('s', payload), ['p1', 'p2'])
        self.assertEqual(payload['n'], len(self.swift_names('s', payload)))

    def test_a_brush_expression_matches_set_filter(self):
        # The shape a header-histogram (or plot-axis) brush emits. It goes through the
        # same compiler as anything typed, so the drawer's count and `set_filter`'s
        # cannot drift.
        self.populated(4)                          # 10, 20, 30, 40
        expr = 'score >= 15 and score <= 35'
        payload = appkit_sets.preview_filter('s', expr)
        self.assertEqual(payload['n'], cmd.set_filter('s', expr))
        self.assertEqual(self.swift_names('s', payload), ['p1', 'p2'])

    def test_empty_expression_is_no_filter(self):
        self.populated(3)
        payload = appkit_sets.preview_filter('s', '')
        self.assertEqual(payload['sql'], '')
        self.assertEqual(payload['params'], [])
        self.assertEqual(payload['n'], 3)
        self.assertEqual(self.swift_names('s', payload), ['p0', 'p1', 'p2'])

    def test_a_rejected_expression_is_a_message_not_a_traceback(self):
        self.populated(2)
        payload = appkit_sets.preview_filter('s', 'score > "x"')
        self.assertIn('float', payload['error'])
        self.assertEqual(payload['offset'], 8)
        self.assertFalse(payload['error'].startswith(' Error:'),
                         'the field shows the message, not CmdException.__str__')
        self.assertEqual(payload['sql'], '')
        self.assertEqual(payload['n'], 0)

    def test_an_unknown_column_names_itself(self):
        self.populated(2)
        payload = appkit_sets.preview_filter('s', 'nosuch > 1')
        self.assertIn("unknown column 'nosuch'", payload['error'])
        self.assertEqual(payload['offset'], 0)

    def test_apply_filter_persists_and_reports(self):
        self.populated(3)
        appkit_sets.open_set('s')
        payload = appkit_sets.apply_filter('s', 'score > 15')
        self.assertEqual(payload['applied'], 1)
        self.assertEqual(payload['n'], 2)
        self.assertEqual(store.active().get_set('s')['filter'], 'score > 15')
        self.assertEqual(len(cmd.set_list('s')), 2)

    def test_apply_filter_reports_a_bad_expression_and_keeps_the_old_one(self):
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        payload = appkit_sets.apply_filter('s', 'score > ')
        self.assertIn('end of input', payload['error'])
        self.assertEqual(store.active().get_set('s')['filter'], 'score > 15',
                         'set_filter validates before it writes')

    def test_a_rejected_apply_does_not_arm_the_poll_to_undo_the_typing(self):
        # A rejected expression writes nothing, so the poll's key must stay the STORED
        # filter. Recording the rejected one instead made the next tick see a mismatch
        # and re-emit the stored filter as APPLIED, which the drawer adopts -- half a
        # second after a typo the field reset itself and the brushes went with it.
        self.populated(3)
        appkit_sets.open_set('s')
        cmd.set_filter('s', 'score > 15')
        with captured():
            appkit_sets.poll()
        payload = appkit_sets.apply_filter('s', 'score > ')
        self.assertEqual(payload['applied'], 0, 'nothing was applied')
        self.assertIn('end of input', payload['error'])
        with captured() as out:
            appkit_sets.poll()
            appkit_sets.poll()
        self.assertEqual(filter_markers(out.getvalue()), [],
                         'the stored filter has not moved, so there is nothing to say')

    def test_clearing_restores_everything(self):
        self.populated(3)
        appkit_sets.apply_filter('s', 'score > 25')
        payload = appkit_sets.apply_filter('s', '')
        self.assertEqual(payload['n'], 3)
        self.assertEqual(store.active().get_set('s')['filter'], '')

    def test_emit_filter_reports_the_saved_filter_without_changing_it(self):
        # What the drawer calls as it opens a set: it reads rows from the file at
        # once, and half a second of showing rows the filter excludes is half a
        # second of the wrong table.
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        clear_filter_channel()
        with captured() as out:
            payload = appkit_sets.emit_filter('s')
        self.assertEqual(len(filter_markers(out.getvalue())), 1)
        self.assertEqual(payload['expr'], 'score > 15')
        self.assertEqual(payload['n'], 2)
        self.assertEqual(payload['applied'], 1)
        self.assertEqual(store.active().get_set('s')['filter'], 'score > 15')

    def test_open_set_arms_the_channel_and_the_poll_emits_after_the_marker(self):
        # ORDER, and it is load-bearing: the drawer clears its filter when the SETS:
        # marker moves the active set, so a SETSFILTER line printed BEFORE that marker
        # would be wiped by it. open_set therefore arms the channel and poll() emits
        # right after printing the marker.
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        with captured():
            appkit_sets.poll()
        clear_filter_channel()
        with captured() as out:
            appkit_sets.open_set('s')
        self.assertEqual(filter_markers(out.getvalue()), [],
                         'open_set itself prints nothing on the filter channel')
        with captured() as out:
            appkit_sets.poll()
        lines = [line for line in out.getvalue().splitlines()
                 if line.startswith((appkit_sets.MARKER_PREFIX, appkit_sets.FILTER_PREFIX))]
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith(appkit_sets.MARKER_PREFIX), lines)
        self.assertTrue(lines[1].startswith(appkit_sets.FILTER_PREFIX), lines)
        self.assertEqual(filter_channel()['expr'], 'score > 15')

    def test_poll_reemits_when_a_console_filter_moves_it(self):
        self.populated(3)
        appkit_sets.open_set('s')
        with captured():
            appkit_sets.poll()
        with captured() as out:
            appkit_sets.poll()
            appkit_sets.poll()
        self.assertEqual(filter_markers(out.getvalue()), [],
                         'an unchanged filter must not be re-sent every tick')
        cmd.set_filter('s', 'score > 25')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(len(filter_markers(out.getvalue())), 1)
        self.assertEqual(filter_channel()['n'], 1)

    def test_a_preview_is_not_pushed_back_by_the_next_poll(self):
        # A preview records the set's STORED expression as the poll's key, so the poll
        # has nothing to say and the half-typed expression survives the next tick.
        self.populated(3)
        appkit_sets.open_set('s')
        with captured():
            appkit_sets.poll()
        appkit_sets.preview_filter('s', 'score > 25')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(filter_markers(out.getvalue()), [])
        self.assertEqual(filter_channel()['expr'], 'score > 25')

    def test_nothing_is_emitted_when_no_set_is_open(self):
        # Requirement 7: with no set open, nothing about the poll changes.
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        with captured() as out:
            appkit_sets.poll()
            appkit_sets.poll()
        self.assertEqual(filter_markers(out.getvalue()), [])
        self.assertIsNone(filter_channel())

    def test_the_filter_follows_a_set_delete(self):
        self.populated(2)
        appkit_sets.open_set('s')
        with captured():
            appkit_sets.poll()
        cmd.set_delete('s')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(filter_markers(out.getvalue()), [],
                         'a set that is gone has no filter to report')


class TestFilterEdges(FilterChannelTestCase):
    """The two ends of the channel the #418 review probed with real containers."""

    def test_an_exact_bound_keeps_the_entry_that_defined_it(self):
        # Blocker 3, end to end: the drawer composes "Filter to selection" from the
        # selected points' own min and max. Printed exactly, the bound keeps the row;
        # printed to six significant figures, it loses it -- and the rows it loses are
        # the extremes, which is what a triage user is hunting.
        cmd.set_create('s')
        c = store.active()
        sid = c.get_set('s')['id']
        specs = mschema.specs(TOOL)
        values = [40.10274153313269, 40.13901288888891, 40.17,
                  40.20419283746519, 40.24152259971877]
        for i, v in enumerate(values):
            c.add_entry(sid, 'd_%d' % i, scalars={'score': v}, specs=specs)
        exact = 'score >= %r and score <= %r' % (min(values), max(values))
        self.assertEqual(appkit_sets.preview_filter('s', exact)['n'], len(values),
                         'an exactly printed bound includes the row that set it')
        lossy = 'score >= %.6g and score <= %.6g' % (min(values), max(values))
        self.assertLess(appkit_sets.preview_filter('s', lossy)['n'], len(values),
                        'six significant figures is what the bug was')

    def test_a_debounced_call_after_a_set_delete_is_not_a_traceback(self):
        # The filter bar's preview and apply fire up to 600 ms after the keystroke; a
        # set_delete in between left them naming a set that no longer exists, and the
        # user saw a SetNotFound traceback in the console for something they did not do.
        self.populated(2)
        appkit_sets.open_set('s')
        cmd.set_delete('s')
        with captured() as out:
            self.assertIsNone(appkit_sets.preview_filter('s', 'score > 1'))
            self.assertIsNone(appkit_sets.apply_filter('s', 'score > 1'))
        self.assertEqual(filter_markers(out.getvalue()), [],
                         'a set that is gone has nothing to report')
        # The command surface an agent scripts against is unchanged.
        from pymol.sets.errors import SetNotFound
        with self.assertRaises(SetNotFound):
            cmd.set_filter('s', 'score > 1')


class TestViewportSelection(FilterChannelTestCase):
    """`sel`: the staged objects of the active set that are in `sele` (#418).

    The object -> entry link is `entries.staged_object`, written when the entry was
    staged. Nothing here keeps a second mapping, and nothing polls for a selection: the
    marker that already fires on change carries it.
    """

    def test_a_selected_staged_object_names_its_entry(self):
        self.populated(2)
        appkit_sets.open_set('s')
        cmd.set_stage('s', 'p1')
        entry = self.entry('s', 'p1')
        cmd.select('sele', 'p1')
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0]['sel'], [entry['id']])

    def test_no_selection_means_no_field(self):
        self.populated(2)
        appkit_sets.open_set('s')
        cmd.set_stage('s', 'p1')
        with captured() as out:
            appkit_sets.poll()
        self.assertNotIn('sel', markers(out.getvalue())[0])

    def test_an_unstaged_entry_is_never_reported(self):
        self.populated(2)
        appkit_sets.open_set('s')
        cmd.fab('AAA', 'unrelated')
        cmd.select('sele', 'unrelated')
        with captured() as out:
            appkit_sets.poll()
        self.assertNotIn('sel', markers(out.getvalue())[0])

    def test_the_idle_marker_is_unchanged(self):
        # An empty `sel` is omitted, so a session with no set prints byte-for-byte
        # what it printed before this ticket.
        with captured() as out:
            appkit_sets.poll()
        self.assertEqual(markers(out.getvalue())[0],
                         {'v': 0, 'path': '', 'active': '', 'peek': '', 'running': {}})


class TestSavedViews(FilterChannelTestCase):

    def test_a_view_round_trips_through_the_container(self):
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        cmd.set_sort('s', 'score', 0)
        cmd.set_view_save('s', 'good', columns='score+name')
        path = os.path.join(self._sets_dir, 'v.raymol')
        cmd.save(path)
        cmd.reinitialize()
        cmd.load(path)
        view = store.active().view(store.active().get_set('s')['id'], 'good')
        self.assertEqual(view['filter'], 'score > 15')
        self.assertEqual(view['sort_key'], 'score')
        self.assertEqual(view['sort_desc'], 0)
        self.assertEqual(view['columns'], ['score', 'name'])
        self.assertEqual(sorted(cmd.set_get('s', 'view:good')), ['p1', 'p2'],
                         'the view still selects the entries it named')

    def test_apply_view_sets_the_filter_and_the_sort(self):
        self.populated(3)
        cmd.set_filter('s', 'score > 25')
        cmd.set_sort('s', 'score', 1)
        cmd.set_view_save('s', 'tight')
        cmd.set_filter('s', '')
        cmd.set_sort('s', 'name', 0)
        appkit_sets.open_set('s')
        with captured() as out:
            appkit_sets.apply_view('s', 'tight')
        row = store.active().get_set('s')
        self.assertEqual(row['filter'], 'score > 25')
        self.assertEqual(row['sort_key'], 'score')
        self.assertEqual(row['sort_desc'], 1)
        self.assertEqual(len(filter_markers(out.getvalue())), 1)
        self.assertEqual(filter_channel()['n'], 1)

    def test_apply_view_of_an_unknown_name_raises(self):
        self.populated(1)
        from pymol.sets.errors import SetNotFound
        with self.assertRaises(SetNotFound):
            appkit_sets.apply_view('s', 'nope')

    def test_columns_accept_a_list_or_a_separated_string(self):
        self.populated(1)
        for given, expected in [('a,b', ['a', 'b']), ('a+b', ['a', 'b']),
                                (['a', 'b'], ['a', 'b']), ('', []),
                                ('  a , , b ', ['a', 'b'])]:
            cmd.set_view_save('s', 'v', columns=given)
            got = store.active().view(store.active().get_set('s')['id'], 'v')
            self.assertEqual(got['columns'], expected, repr(given))


# --------------------------------------------------------------------------- #419
# The cross-language contract for residue arrays.
#
# The Sequences tab draws a per-residue heat strip under every row, and Swift decodes
# those arrays ITSELF, from the blob, with no round trip to Python (#419 decision 1).
# It can, because the format is fixed: little-endian float32, one value per
# `index_json` entry, NaN for absent, and only `cif` blobs are gzipped. But "it can"
# is a claim, and a claim about bytes crossing a language boundary is exactly the kind
# that holds until someone changes an encoder.
#
# So the two halves are pinned against each other through ONE FILE. The Python side
# below writes known values through `pymol.sets.blobs` into
# `swiftui/PyMOLViewerTests/Fixtures/residue_arrays.raymol`, which is committed;
# `SequenceArrayTests` in Swift opens that same file and asserts the same floats come
# back. Either side changing its mind is a red test on the other.
#
# Regenerate with RAYMOL_WRITE_SWIFT_FIXTURE=1, which is also how it was first made.
# Without it, this test REBUILDS the container into a temp file and compares the array
# blobs byte for byte against the committed one -- so the committed fixture cannot
# quietly fall behind the encoder that is supposed to have produced it.

#: (chain, resi) pairs and values written into the fixture. Every value is exactly
#: representable as a float32, so "the same floats come back" is an equality and not
#: an epsilon: a tolerance here would hide precisely the bug this test is for.
FIXTURE_SET = 'seqfix'
FIXTURE_PLDDT_INDEX = [('A', '1'), ('A', '2'), ('A', '3'), ('B', '10'), ('B', '11')]
#: Note the None: `blobs.encode_f32` writes it as NaN, and `decode_f32` (and Swift)
#: must read it back as absent rather than as 0.0. An unmeasured residue is not a
#: residue that scored zero -- the metrics store's rule, all the way down to the bytes.
FIXTURE_PLDDT = [91.5, 88.25, None, 70.0, 42.125]
FIXTURE_NF_INDEX = [('A', '1'), ('A', '2'), ('A', '3')]
FIXTURE_NF = [-1.5, -0.25, -6.0]
FIXTURE_CERTAINTY = [0.0, 0.5, 1.0, None, 0.25]
FIXTURE_SEQUENCES = {'A': 'MKV', 'B': 'GG'}
FIXTURE_CHILD_SEQUENCES = {'A': 'MRV', 'B': 'GG'}


def swift_fixture_path():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    return os.path.join(root, 'swiftui', 'PyMOLViewerTests', 'Fixtures',
                        'residue_arrays.raymol')


def build_swift_fixture(path):
    """Lay down the cross-language fixture at `path`. Returns the Container."""
    specs = [
        mschema.MetricSpec('plddt', mschema.RESIDUE, lo=0, hi=100,
                           higher_is_better=True, label='pLDDT'),
        mschema.MetricSpec('native_fit', mschema.RESIDUE, lo=-6, hi=0,
                           higher_is_better=True, label='Native fit'),
        mschema.MetricSpec('certainty', mschema.RESIDUE, lo=0, hi=1,
                           higher_is_better=True, label='Certainty'),
        mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100,
                           higher_is_better=True),
    ]
    container = store.Container(path)
    set_id = container.create_set(FIXTURE_SET, tool='seqfixtool',
                                  ranking_key='score')['id']
    container.declare_columns(set_id, specs)
    run_id = container.add_run(set_id, 'seqfixtool')
    parent = container.add_entry(
        set_id, 'p_0001', run_id=run_id, sequences=FIXTURE_SEQUENCES,
        scalars={'score': 80.0},
        arrays=[
            # Whole-entry, MULTI-CHAIN index: the case that decides whether the strip
            # under a two-chain row lines up. A per-chain array follows it, so the
            # reader has to key by chain name rather than by the order it met them.
            dict(key='plddt', scope='residue', chain=None,
                 index=FIXTURE_PLDDT_INDEX, values=FIXTURE_PLDDT, spec=specs[0]),
            dict(key='native_fit', scope='residue', chain='A',
                 index=FIXTURE_NF_INDEX, values=FIXTURE_NF, spec=specs[1]),
            dict(key='certainty', scope='residue', chain=None,
                 index=FIXTURE_PLDDT_INDEX, values=FIXTURE_CERTAINTY, spec=specs[2]),
        ])
    container.add_entry(set_id, 'c_0001', run_id=run_id, parents=[parent],
                        sequences=FIXTURE_CHILD_SEQUENCES, scalars={'score': 91.0},
                        arrays=[dict(key='plddt', scope='residue', chain=None,
                                     index=FIXTURE_PLDDT_INDEX,
                                     values=FIXTURE_PLDDT, spec=specs[0])])
    container.close()
    settle_fixture(path)


def settle_fixture(path):
    """Take the fixture out of WAL mode and vacuum it.

    A `.raymol` runs in WAL (store spec §2.1) and a WAL database needs a `-shm` beside
    it even to be READ, so every run of these tests -- and every run of the Swift ones,
    which open the same file -- would drop two untracked sidecars next to a committed
    file and, on a read-only checkout, might not be able to open it at all. Journal
    mode is a header byte and not part of any blob, so a rollback-journal fixture is
    byte-identical where it matters and openable by anything, anywhere.
    """
    import sqlite3 as _sqlite3
    conn = _sqlite3.connect(path, isolation_level=None)
    try:
        conn.execute('PRAGMA journal_mode=DELETE')
        conn.execute('VACUUM')
    finally:
        conn.close()
    for suffix in ('-wal', '-shm'):
        try:
            os.remove(path + suffix)
        except OSError:
            pass


def array_blobs(path):
    """{(entry name, key, chain): (encoding, index_json, bytes)} for one container."""
    import sqlite3 as _sqlite3
    conn = _sqlite3.connect('file:%s?mode=ro' % path, uri=True)
    try:
        rows = conn.execute(
            'SELECT e.name, a.key, a.chain, a.encoding, a.index_json, b.bytes'
            ' FROM arrays a JOIN blobs b ON b.hash = a.blob'
            ' JOIN entries e ON e.id = a.entry_id ORDER BY e.name, a.key').fetchall()
    finally:
        conn.close()
    return {(r[0], r[1], r[2]): (r[3], r[4], bytes(r[5])) for r in rows}


class TestSwiftResidueArrayFixture(AppkitSetsTestCase):

    def test_the_committed_fixture_is_what_this_encoder_writes(self):
        fixture = swift_fixture_path()
        if os.environ.get('RAYMOL_WRITE_SWIFT_FIXTURE'):
            if os.path.exists(fixture):
                store.remove_db_files(fixture)
            build_swift_fixture(fixture)
        self.assertTrue(os.path.exists(fixture),
                        'the committed fixture is missing; regenerate it with'
                        ' RAYMOL_WRITE_SWIFT_FIXTURE=1 and commit it')
        fresh = os.path.join(self._sets_dir, 'fresh.raymol')
        build_swift_fixture(fresh)
        # Byte for byte. The blobs are content-addressed by the sha256 of exactly
        # these bytes, so a difference here is a different encoder, which is the one
        # thing that could make Swift's decode wrong without any Swift changing.
        self.assertEqual(array_blobs(fixture), array_blobs(fresh),
                         'the committed fixture no longer matches what'
                         ' pymol.sets.blobs writes; regenerate it with'
                         ' RAYMOL_WRITE_SWIFT_FIXTURE=1')

    def test_python_reads_back_exactly_what_swift_asserts(self):
        """The expected values, read through the Python decoder.

        The same numbers are written out in `SequenceArrayTests.swift`. Two copies on
        purpose: a shared constant would let both sides drift together, and the point
        is that two independent decoders agree about one file.
        """
        import shutil
        copied = os.path.join(self._sets_dir, 'read.raymol')
        shutil.copyfile(swift_fixture_path(), copied)
        container = store.Container(copied)
        try:
            set_id = container.get_set(FIXTURE_SET)['id']
            entries = {e['name']: e for e in container.entries(set_id)}
            parent = entries['p_0001']
            index, values = container.array(parent['id'], 'plddt')
            self.assertEqual([tuple(p) for p in index], FIXTURE_PLDDT_INDEX)
            self.assertEqual(values, FIXTURE_PLDDT)
            index, values = container.array(parent['id'], 'native_fit', chain='A')
            self.assertEqual([tuple(p) for p in index], FIXTURE_NF_INDEX)
            self.assertEqual(values, FIXTURE_NF)
            _, values = container.array(parent['id'], 'certainty')
            self.assertEqual(values, FIXTURE_CERTAINTY)
            self.assertEqual(parent['sequences'], FIXTURE_SEQUENCES)
            child = entries['c_0001']
            self.assertEqual(child['parents'], [parent['id']],
                             'the child carries the parent link the Lineage tab reads')
            self.assertEqual(child['sequences'], FIXTURE_CHILD_SEQUENCES)
        finally:
            container.close()

    def test_residue_arrays_are_f32_and_ungzipped(self):
        """The two facts Swift's decoder is built on (#419 decision 1).

        `blobs.choose_encoding` gives u8q to PAIR scope only, and only `cif` blobs are
        gzipped -- so a residue array is raw little-endian float32 and needs no
        decompression on the Swift side. If either ever changes, the strip would draw
        noise, so the assertion is here rather than in a comment.
        """
        for (name, key, chain), (encoding, _, raw) in \
                array_blobs(swift_fixture_path()).items():
            self.assertEqual(encoding, 'f32',
                             'residue array %s/%s is %s' % (name, key, encoding))
            self.assertNotEqual(raw[:2], b'\x1f\x8b',
                                '%s/%s is gzipped; Swift does not decompress' % (name, key))
        blob = array_blobs(swift_fixture_path())[('p_0001', 'plddt', None)][2]
        self.assertEqual(len(blob), 4 * len(FIXTURE_PLDDT))
        self.assertEqual(blob[:4], struct.pack('<f', 91.5),
                         'little-endian float32, first value first')


class TestLineageFilterGrammarLimits(AppkitSetsTestCase):
    """What the grammar can and cannot say about "these descendants" (#419).

    Spec §4.5 says clicking a Lineage node "filters the table to its descendants". The
    drawer SELECTS instead, and this pins the two halves of why -- being careful about
    which half is a limit and which is a choice, because the first version of this
    claimed more than it could show.

    The limit is real: there is no `id` column to name, and `in` is refused on the two
    entry columns that do exist. If the grammar ever grows an id column the first two
    tests go red and the decision can be revisited on purpose.

    The rest is a choice. Entry names are unique within a set and an or-chain of them
    compiles perfectly well -- `test_an_or_chain_of_names_compiles_fine` builds one and
    checks the SQL and the bound parameters -- so "these 212 descendants" IS
    expressible. We decline to synthesise it: a 212-term expression written by the UI
    is not something a user could read, edit or save as a view, it would be regenerated
    on every click, and it would put a second producer of filter text beside
    `SetFilterComposer`. A selection is what "these specific rows" is for.
    """

    def test_id_is_not_a_column_the_grammar_knows(self):
        from pymol.sets import filter as setfilter
        from pymol.sets.errors import SetFilterError
        columns = {'score': 'float'}
        with self.assertRaises(SetFilterError) as caught:
            setfilter.compile("id in ('e1', 'e2')", columns)
        self.assertIn('id', str(caught.exception))

    def test_in_is_refused_on_name(self):
        from pymol.sets import filter as setfilter
        from pymol.sets.errors import SetFilterError
        with self.assertRaises(SetFilterError) as caught:
            setfilter.compile("name in ('d_0001', 'd_0002')", {'score': 'float'})
        self.assertIn("'in' is not valid on name", str(caught.exception))

    def test_a_single_name_compiles(self):
        from pymol.sets import filter as setfilter
        sql, params = setfilter.compile("name = 'd_0001'", {'score': 'float'})
        self.assertIn('e."name"', sql)
        self.assertEqual(list(params), ['d_0001'])

    def test_an_or_chain_of_names_compiles_fine(self):
        """So the click's justification is a CHOICE, not an impossibility.

        Asserted rather than asserted-about: the comment in LineageView.swift used to
        say no or-chain could be built, which was untested opinion and wrong.
        """
        from pymol.sets import filter as setfilter
        names = ['d_%04d' % i for i in range(212)]
        expr = ' or '.join("name = '%s'" % n for n in names)
        sql, params = setfilter.compile(expr, {'score': 'float'})
        self.assertEqual(list(params), names,
                         'all 212 are bound parameters; nothing is spliced into SQL')
        self.assertEqual(sql.count('e."name"'), 212)

    def test_an_or_chain_of_names_really_selects_those_entries(self):
        """Not just valid SQL -- it does the job. Which is why the reason the drawer
        does not build one has to be about the EXPRESSION being unreadable, not about
        the grammar being unable."""
        self.populated(3)
        cmd.set_filter('s', "name = 'p0' or name = 'p2'")
        self.assertEqual(sorted(cmd.set_get('s', 'filtered')), ['p0', 'p2'])
