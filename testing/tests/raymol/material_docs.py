"""docs/materials.md stays in step with the material table and settings (#500).

The page is the user's reference for every material and setting. A material
added to the table, or a material setting added to SettingInfo.h, without a
line in the docs ships undocumented -- and nothing else would notice.

Source-reading, so skipped (not passed) outside a repo checkout.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_docs.py
"""
import os

from pymol import setting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
DOC = os.path.join(ROOT, 'docs', 'materials.md')

# Settings that belong to the materials feature, derived from the setting
# names rather than listed, so a new one cannot be added without a row:
# every `*_material`, every `material_*`, and the peel control.
def material_settings():
    return sorted(n for n in setting.get_name_list()
                  if n.endswith('_material') or n.startswith('material_')
                  or n == 'transparency_peel')


def section(doc, heading):
    """The text under `## heading`, up to the next `## `. A row is only
    documented if it is in ITS table -- the page has several tables that
    mention the same names (the CPU ray table lists seven materials), so a
    whole-page search passes for a row that was deleted."""
    start = doc.index('\n## %s\n' % heading)
    end = doc.find('\n## ', start + 1)
    return doc[start:end if end >= 0 else len(doc)]


def first_cells(text):
    return {line.split('|')[1].strip().strip('`')
            for line in text.splitlines()
            if line.startswith('| `')}


class TestMaterialDocs(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        if not os.path.isfile(DOC):
            self.skipTest('docs/materials.md not present; not a repo checkout')
        with open(DOC, encoding='utf-8') as handle:
            self.doc = handle.read()

    def testEveryImplementedMaterialHasARowInTheMaterialsTable(self):
        names = [n for _i, n in setting.get_material_names(1)]
        self.assertGreaterEqual(len(names), 10)
        rows = first_cells(section(self.doc, 'The materials'))
        for name in names:
            self.assertIn(name, rows, name)

    def testEveryMaterialSettingHasARowInTheSettingsTable(self):
        names = material_settings()
        # the derivation must find the seven the feature shipped with, or it
        # is matching nothing
        self.assertGreaterEqual(len(names), 7, names)
        rows = first_cells(section(self.doc, 'Settings'))
        for name in names:
            self.assertIn(name, rows, name)
