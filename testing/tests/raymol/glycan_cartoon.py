"""Tests for pymol.raymol_glycan.

Runs via the repository test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/glycan_cartoon.py
"""

from pymol import cgo, cmd, metal_pick, raymol_glycan, testing


def _add_ring(object_name, residue_name, residue_number, offset=0.0, chain="A"):
    coordinates = {
        "C1": (0.0, 0.0, 0.0),
        "C2": (2.0, 0.0, 0.0),
        "C3": (2.0, 2.0, 0.0),
        "C4": (0.0, 2.0, 0.0),
        "C5": (0.0, 1.0, 0.0),
        "O5": (2.0, 1.0, 0.0),
    }
    for atom_name, coordinate in coordinates.items():
        cmd.pseudoatom(
            object_name,
            resn=residue_name,
            name=atom_name,
            pos=[coordinate[0] + offset, coordinate[1], coordinate[2]],
            chain=chain,
            segi="",
            resi=str(residue_number),
        )


class TestRayMolGlycan(testing.PyMOLTestCase):
    def testOfficialSNFGColors(self):
        for index, residue_name in enumerate(raymol_glycan.SNFG_CATALOG, 1):
            cmd.pseudoatom(
                f"test_{residue_name}",
                resn=residue_name,
                name="C2",
                pos=[float(index), 0.0, 0.0],
            )

        applied = raymol_glycan.glycocolor("all")
        self.assertEqual(applied, len(raymol_glycan.SNFG_CATALOG))
        for residue_name, specification in raymol_glycan.SNFG_CATALOG.items():
            self.assertArrayEqual(
                cmd.get_color_tuple(f"snfg_{residue_name.lower()}"),
                specification["color"],
                delta=1e-5,
            )

    def testCentroidExcludesPyranoseC6(self):
        _add_ring("test_nag", "NAG", 1, chain="")
        cmd.pseudoatom(
            "test_nag",
            resn="NAG",
            name="C6",
            pos=[500.0, 500.0, 500.0],
            segi="",
            resi="1",
        )

        model = cmd.get_model("test_nag")
        _, centroids = raymol_glycan._build_glycocartoon_cgo(
            model, size=2.5, draw_linkers=0
        )
        key = ("test_nag", "", "", "1", "NAG")
        self.assertIn(key, centroids)
        self.assertArrayEqual(centroids[key], [1.0, 1.0, 0.0], delta=1e-6)

    def testLinkersFollowCovalentTopology(self):
        object_name = "test_disaccharide"
        _add_ring(object_name, "MAN", 1)
        _add_ring(object_name, "GAL", 2, offset=4.0)

        unbonded, _ = raymol_glycan._build_glycocartoon_cgo(cmd.get_model(object_name))
        self.assertNotIn(cgo.CYLINDER, unbonded)

        cmd.bond(
            f"/{object_name}//A/1/C1",
            f"/{object_name}//A/2/C4",
        )
        bonded, _ = raymol_glycan._build_glycocartoon_cgo(cmd.get_model(object_name))
        self.assertIn(cgo.CYLINDER, bonded)
        cylinder_index = bonded.index(cgo.CYLINDER)
        linker_colors = bonded[cylinder_index + 8:cylinder_index + 14]
        self.assertArrayEqual(
            linker_colors,
            [*raymol_glycan.GREEN, *raymol_glycan.YELLOW],
            delta=1e-6,
        )

    def testIncompleteAndUnsupportedResiduesAreSkipped(self):
        cmd.pseudoatom("partial", resn="NAG", name="C1", pos=[0.0, 0.0, 0.0])
        cmd.pseudoatom("ligand", resn="LIG", name="C1", pos=[1.0, 0.0, 0.0])
        cgo_data, centroids = raymol_glycan._build_glycocartoon_cgo(cmd.get_model("all"))
        self.assertEqual(cgo_data, [])
        self.assertEqual(centroids, {})

    def testCartoonIsIdempotentAndCleanupIsTargeted(self):
        _add_ring("objA", "MAN", 1)
        _add_ring("objB", "GAL", 1)
        self.assertEqual(raymol_glycan.glycocartoon("objA"), 1)
        self.assertEqual(raymol_glycan.glycocartoon("objA"), 1)
        self.assertEqual(raymol_glycan.glycocartoon("objB"), 1)

        object_a = raymol_glycan._get_deterministic_cgo_name("objA")
        object_b = raymol_glycan._get_deterministic_cgo_name("objB")
        generated = [name for name in cmd.get_names("objects") if name.startswith("cgo_glyco_")]
        self.assertEqual(set(generated), {object_a, object_b})

        targets = raymol_glycan.get_pick_targets()
        target_a = next(target for target in targets if target["cgo_object"] == object_a)
        self.assertEqual(target_a["object"], "objA")
        self.assertEqual(target_a["resn"], "MAN")
        self.assertEqual(target_a["resi"], "1")
        self.assertEqual(target_a["name"], "C1")

        raymol_glycan.glycocartoon_hide("objA")
        self.assertNotIn(object_a, cmd.get_names("objects"))
        self.assertIn(object_b, cmd.get_names("objects"))
        self.assertNotIn(object_a, {
            target["cgo_object"] for target in raymol_glycan.get_pick_targets()
        })

    def testExistingRepresentationsRemainVisible(self):
        _add_ring("visible_nag", "NAG", 1)
        cmd.show("sticks", "visible_nag")
        before = []
        cmd.iterate("visible_nag", "before.append(reps)", space={"before": before})

        raymol_glycan.glycocartoon("visible_nag")

        after = []
        cmd.iterate("visible_nag", "after.append(reps)", space={"after": after})
        self.assertEqual(after, before)

    def testCartoonSymbolPicksUnderlyingResidue(self):
        _add_ring("pickable_man", "MAN", 7, chain="G")
        cmd.hide("everything", "pickable_man")
        self.assertEqual(raymol_glycan.glycocartoon("pickable_man"), 1)
        cmd.set_view((
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
            0.0, 0.0, -50.0,
            1.0, 1.0, 0.0,
            40.0, 100.0, -20.0,
        ))

        hit = metal_pick._pick_atom(0.0, 0.0, 1.0)
        self.assertIsNotNone(hit)
        self.assertEqual(hit[1:7], ("pickable_man", "G", "7", "MAN", "G", "C1"))
