"""Every Inspector command that interpolates an object NAME goes through the
name guard (#531).

ObjectPanel.swift builds PyMOL commands by interpolating names into command
language. With `validate_object_names` off, a name can carry a line break or
`;` and split the command. engine.runCommand(_:naming:) refuses a command
whose names are outside PyMOL's own alphabet. This test fails if a builder
interpolates one of the panel's name variables without passing it through
`naming:` -- the regression a new button would otherwise introduce silently.

Source-reading, so skipped (not passed) outside a repo checkout.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/inspector_command_names.py
"""
import os
import re

from pymol import testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
PANEL = os.path.join(ROOT, 'swiftui', 'PyMOLViewer', 'Panels',
                     'ObjectPanel.swift')

# Every variable ObjectPanel.swift interpolates a name or name-like token
# through. A new builder that interpolates one of these must be guarded.
NAME_VARS = ('name', 'objName', 'entry.name', 'entry.target', 'entry.chain',
             'sel.name', 'member', 'target.name', 'g.name', 'escaped', 'sele',
             'new', 'mobile', 'target', 'selection', 'g')

# Commands passed in NON-literally (a variable or a builder call) cannot be
# checked for interpolation at the call site, so each must carry a guard --
# except these, which build their text from no name at all.
UNNAMED_BUILDERS = ('CameraCommands.setAutofocus(',)

ENGINE = os.path.join(ROOT, 'swiftui', 'PyMOLViewer', 'Shared',
                      'PyMOLEngine.swift')


def calls(text):
    """(line number, argument text) of every engine.runCommand( call."""
    for m in re.finditer(r'engine\.runCommand\(', text):
        i = m.end()
        depth = 1
        while depth and i < len(text):
            depth += {'(': 1, ')': -1}.get(text[i], 0)
            i += 1
        yield text.count('\n', 0, m.start()) + 1, text[m.end():i - 1]


class TestInspectorCommandNames(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        if not os.path.isfile(PANEL):
            self.skipTest('ObjectPanel.swift not present; not a repo checkout')
        with open(PANEL, encoding='utf-8') as handle:
            self.src = handle.read()

    def testEveryNameInterpolatingCommandIsGuarded(self):
        unguarded = []
        n = 0
        for line, arg in calls(self.src):
            guarded = 'naming:' in arg or 'tokens:' in arg
            literal = arg.lstrip().startswith('"')
            if not literal:
                # built elsewhere: needs a guard unless it names nothing
                if not guarded and not arg.lstrip().startswith(UNNAMED_BUILDERS):
                    unguarded.append('%d: non-literal %s' % (line, arg.strip()[:40]))
                n += 1
                continue
            names = [v for v in NAME_VARS if '\\(%s)' % v in arg]
            # ...and ANY interpolated `*name` / `*Name` variable, so a new
            # builder with a new variable name is caught too
            names += [v for v in re.findall(r'\\\(([A-Za-z_.]*(?:name|Name))\)', arg)
                      if v not in names]
            if names:
                n += 1
                if not guarded:
                    unguarded.append('%d: %s' % (line, names))
        # the scan must find the builders, or it checks nothing
        self.assertGreater(n, 40)
        self.assertEqual(unguarded, [])

    def testTheEngineHelpersTheInspectorCallsAreGuarded(self):
        # setObjectEnabled (the visibility checkbox) and the state-playback
        # timer build their commands inside PyMOLEngine, out of the scan above.
        with open(ENGINE, encoding='utf-8') as handle:
            engine = handle.read()
        self.assertIn('"disable \\(name)", naming: name)', engine)
        self.assertIn('"set state, \\(k), \\(name)", naming: name)', engine)
        self.assertIn('"set state, \\(n), \\(name)", naming: name)', engine)

    def testTheGuardRefusesByTheNameAlphabet(self):
        body = self.src[self.src.index('func runCommand(_ command: String, naming'):]
        body = body[:body.index('\n    }\n')]
        self.assertIn('names.allSatisfy(isLegalObjectName)', body)
        self.assertIn('tokens.allSatisfy(isCommandSafeToken)', body)
        self.assertIn('return', body)
