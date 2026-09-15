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

    def test_clearing_restores_everything(self):
        self.populated(3)
        appkit_sets.apply_filter('s', 'score > 25')
        payload = appkit_sets.apply_filter('s', '')
        self.assertEqual(payload['n'], 3)
        self.assertEqual(store.active().get_set('s')['filter'], '')

    def test_open_set_emits_the_saved_filter_at_once(self):
        self.populated(3)
        cmd.set_filter('s', 'score > 15')
        clear_filter_channel()
        with captured() as out:
            appkit_sets.open_set('s')
        self.assertEqual(len(filter_markers(out.getvalue())), 1)
        payload = filter_channel()
        self.assertEqual(payload['expr'], 'score > 15')
        self.assertEqual(payload['n'], 2)

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
