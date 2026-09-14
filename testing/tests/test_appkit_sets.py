"""Tests for pymol.appkit_sets -- the SETS: change marker and the drawer helpers (#417).

The object panel's 500 ms poll must not grow with the number of entries in a set
(#271, #398, #421), so set contents never travel over the feedback channel: Swift
reads the .raymol file itself and re-reads only when the marker's version changes.
These tests pin the marker's contract -- what it carries, when it is (and is not)
printed, that polling never creates a working file, that it stays under PyMOL's
1024-byte feedback-line cap -- and the helpers the drawer calls.

    pymol -ckqy testing/testing.py --run testing/tests/test_appkit_sets.py
"""
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
        mschema.register(TOOL, [
            mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100, higher_is_better=True),
            mschema.MetricSpec('rmsd', mschema.STATE, lo=0, hi=10, units='A'),
        ], replace=True)
        # The module keeps the last marker and the drawer ids; every test starts from
        # "nothing printed yet, nothing open, nothing peeked".
        self._had_batch = sys.modules.get(BATCH_MODULE)
        sys.modules.pop(BATCH_MODULE, None)
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
        testing.PyMOLTestCase.tearDown(self)

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

    def test_marker_stays_under_the_feedback_cap(self):
        self.populated(1)
        appkit_sets.open_set('s')
        appkit_sets.peek('s', 'p0')
        self.install_fake_batch({
            ('%08x' % i): {'done': i, 'total': 1000, 'tool': 'binder_design'}
            for i in range(40)})
        text = appkit_sets.marker()
        self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH)
        payload = json.loads(text[len(appkit_sets.MARKER_PREFIX):])
        self.assertEqual(payload['trunc'], 1)
        # The COUNTS go first, not the sets: the badge must still appear on the
        # right rows saying "a batch is running", because a vanished badge reads as
        # "the batch finished".
        self.assertEqual(len(payload['running']), 40)
        self.assertEqual(set(map(tuple, (sorted(v.items()) for v in payload['running'].values()))),
                         {tuple(sorted(appkit_sets.EMPTY_PROGRESS.items()))})
        self.assertTrue(payload['path'])
        self.assertTrue(payload['active'])
        self.assertTrue(payload['peek'])

    def test_marker_drops_running_entirely_when_even_the_ids_do_not_fit(self):
        # Second stage: hundreds of concurrent batches. The fields the drawer
        # cannot work without survive; `running` is what goes.
        self.populated(1)
        appkit_sets.open_set('s')
        self.install_fake_batch({
            ('%08x' % i): {'done': i, 'total': 1000, 'tool': 'binder_design'}
            for i in range(400)})
        text = appkit_sets.marker()
        self.assertLess(len(text.encode('utf-8')), ORTHO_LINE_LENGTH)
        payload = json.loads(text[len(appkit_sets.MARKER_PREFIX):])
        self.assertEqual(payload['running'], {})
        self.assertEqual(payload['trunc'], 1)
        self.assertTrue(payload['path'])
        self.assertTrue(payload['active'])

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
