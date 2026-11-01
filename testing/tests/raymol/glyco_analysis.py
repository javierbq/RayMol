"""Focused tests for RayMol's dependency-free glycan analysis layer."""

import json
import math

from pymol import cmd, glyco, testing
from pymol.glyco._geometry import dihedral
from pymol.glyco.puckering import cremer_pople_six


def _add_residue(object_name, resn, resi, offset=0.0):
    coordinates = {
        "C1": (0.0, 0.0, 0.45),
        "C2": (1.4, 0.0, -0.35),
        "C3": (2.1, 1.2, 0.35),
        "C4": (1.4, 2.4, -0.45),
        "C5": (0.0, 2.4, 0.35),
        "O5": (-0.7, 1.2, -0.35),
    }
    for name, coordinate in coordinates.items():
        cmd.pseudoatom(object_name, resn=resn, resi=str(resi), chain="G", name=name,
                       pos=[coordinate[0] + offset, coordinate[1], coordinate[2]])


class TestGlycoAnalysis(testing.PyMOLTestCase):
    def testCatalogClassificationIsNonMutating(self):
        result = glyco.classify_residue("NAG", ["C1", "O5"])
        self.assertTrue(result["recognized"])
        self.assertEqual(result["symbol"], "GlcNAc")
        self.assertEqual(result["color"], "#0072BC")

        unknown = glyco.classify_residue(
            "UNX", ["C1", "C2", "C3", "C4", "C5", "O5"]
        )
        self.assertFalse(unknown["recognized"])
        self.assertEqual(unknown["confidence"], "advisory")

    def testDependencyFreeGeometry(self):
        angle = dihedral((1, 0, 0), (0, 0, 0), (0, 1, 0), (0, 1, 1))
        self.assertTrue(math.isfinite(angle))
        puckering = cremer_pople_six([
            (0.0, 0.0, 0.45), (1.4, 0.0, -0.35), (2.1, 1.2, 0.35),
            (1.4, 2.4, -0.45), (0.0, 2.4, 0.35), (-0.7, 1.2, -0.35),
        ])
        self.assertIsNotNone(puckering)
        self.assertGreater(puckering["Q"], 0.0)
        self.assertTrue(puckering["advisory"])

    def testForestUsesCovalentTopologyAndAttachmentRoot(self):
        _add_residue("glycan", "MAN", 1)
        _add_residue("glycan", "NAG", 2, offset=4.0)
        cmd.pseudoatom("glycan", resn="ASN", resi="20", chain="A", name="ND2",
                       pos=[-1.0, 0.0, 0.45])
        cmd.bond("/glycan//G/1/C1", "/glycan//G/2/O5")
        cmd.bond("/glycan//G/1/C2", "/glycan//A/20/ND2")

        payload = glyco.build_glycan_forest(cmd.get_model("glycan"))
        self.assertEqual(payload["residueCount"], 2)
        self.assertEqual(payload["componentCount"], 1)
        root = payload["roots"][0]
        self.assertEqual(root["resi"], "1")
        self.assertEqual(root["children"][0]["resi"], "2")
        self.assertIn("linkage", root["children"][0])

    def testDisconnectedResiduesAreSeparateComponentsAndJSONSafe(self):
        _add_residue("separate", "GAL", 8)
        _add_residue("separate", "FUC", 9, offset=5.0)
        payload = glyco.build_glycan_forest(cmd.get_model("separate"))
        self.assertEqual(payload["componentCount"], 2)
        self.assertEqual(json.loads(json.dumps(payload))["residueCount"], 2)

    def testCommandReturnsJSON(self):
        _add_residue("command", "NAG", 1)
        payload = json.loads(glyco.glyco_tree("command"))
        self.assertEqual(payload["roots"][0]["snfg"]["symbol"], "GlcNAc")
