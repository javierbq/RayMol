"""RayMol's own MCP tools (raymol_mcp/native.py) against the real cmd API.

Runs under the embedded pymol (testing.py), like the rest of the MCP tests:
the tools wrap fork commands (lights, atmosphere, *_material, metal_*), so a
stand-in cmd would only test the stand-in.
"""

import json
import os
import tempfile
import unittest

import pymol
from pymol import cmd

import raymol_mcp.mainthread as mainthread
import raymol_mcp.native as native
import raymol_mcp.tools as tools


def claim_main_thread(testcase):
    """Make this thread the app's main thread so run_on_main runs inline
    (see test_mcp_tools.claim_main_thread)."""
    testcase.addCleanup(setattr, mainthread, "_main_ident",
                        mainthread._main_ident)
    mainthread.drain_main_thread_queue()


def _payload(res):
    """The JSON value a native tool appends after any printed text."""
    text = res["content"][0]["text"]
    return json.loads(text[text.index("{"):])


class _NativeCase(unittest.TestCase):
    def setUp(self):
        claim_main_thread(self)
        cmd.reinitialize()
        cmd.fragment("ala")
        self.addCleanup(cmd.reinitialize)


class TestSetLighting(_NativeCase):
    def test_preset_turns_the_rig_on(self):
        res = tools.call("set_lighting", {"preset": "three_point"})
        self.assertFalse(res["isError"], res)
        rig = _payload(res)["lights"]
        self.assertTrue(rig["enabled"])
        self.assertEqual({l["name"] for l in rig["lights"]},
                         {l["name"] for l in cmd.get_lights()["lights"]})

    def test_edit_and_add_lights_by_name(self):
        tools.call("set_lighting", {"preset": "three_point"})
        res = tools.call("set_lighting", {"lights": [
            {"name": "key", "orbit": -60, "warmth": 3200},
            {"name": "glow", "orbit": 170, "color": "cyan", "shadow": False},
        ]})
        self.assertFalse(res["isError"], res)
        lights = {l["name"]: l for l in cmd.get_lights()["lights"]}
        self.assertAlmostEqual(lights["key"]["orbit"], -60)
        self.assertAlmostEqual(lights["key"]["warmth"], 3200)
        self.assertIn("glow", lights)

    def test_mode_off_keeps_the_rig(self):
        tools.call("set_lighting", {"preset": "neon"})
        res = tools.call("set_lighting", {"mode": "off"})
        self.assertFalse(res["isError"], res)
        self.assertFalse(cmd.get_lights()["enabled"])

    def test_bad_field_is_the_commands_own_error(self):
        tools.call("set_lighting", {"preset": "three_point"})
        res = tools.call("set_lighting",
                         {"lights": [{"name": "key", "pitch": 400}]})
        self.assertTrue(res["isError"])
        self.assertIn("pitch", res["content"][0]["text"])
        self.assertNotIn("Traceback", res["content"][0]["text"])

    def test_preset_with_off_is_refused(self):
        res = tools.call("set_lighting", {"preset": "neon", "mode": "off"})
        self.assertTrue(res["isError"])


class TestAtmosphere(_NativeCase):
    def test_sets_and_resets_air(self):
        res = tools.call("set_atmosphere", {"haze": 0.3, "dust": 0.5})
        self.assertFalse(res["isError"], res)
        self.assertAlmostEqual(_payload(res)["air"]["haze"], 0.3)
        tools.call("set_atmosphere", {"off": True})
        self.assertAlmostEqual(cmd.get_lights()["air"]["haze"], 0.0)


class TestMaterial(_NativeCase):
    def test_per_object_and_representation(self):
        res = tools.call("set_material", {"material": "glass", "object": "ala",
                                          "representations": ["surface"]})
        self.assertFalse(res["isError"], res)
        self.assertEqual(cmd.get("surface_material", "ala"), "glass")
        self.assertEqual(cmd.get("cartoon_material", "ala"), "default")

    def test_no_object_sets_the_default(self):
        tools.call("set_material", {"material": "matte"})
        self.assertEqual(cmd.get("material_default"), "matte")

    def test_unknown_material_is_an_error(self):
        res = tools.call("set_material", {"material": "glas", "object": "ala"})
        self.assertTrue(res["isError"])

    def test_unknown_representation_is_an_error(self):
        res = tools.call("set_material", {"material": "glass", "object": "ala",
                                          "representations": ["ribbon"]})
        self.assertTrue(res["isError"])


class TestRenderEffects(_NativeCase):
    def test_sets_only_given_fields_and_reports_all(self):
        before = cmd.get("metal_ssao")
        res = tools.call("set_render_effects",
                         {"outline": True, "exposure": 1.5})
        self.assertFalse(res["isError"], res)
        state = _payload(res)
        self.assertEqual(set(state), set(native.EFFECTS))
        self.assertEqual(cmd.get("metal_outline"), "on")
        self.assertAlmostEqual(float(cmd.get("metal_exposure")), 1.5)
        self.assertEqual(cmd.get("metal_ssao"), before)


class TestExportImage(_NativeCase):
    def test_writes_a_png(self):
        # No Metal view here (GLUT build): the CPU tracer fallback, labelled.
        path = os.path.join(tempfile.mkdtemp(), "out.png")
        res = tools.call("export_image",
                         {"path": path, "width": 64, "height": 48})
        self.assertFalse(res["isError"], res)
        self.assertGreater(os.path.getsize(path), 0)
        self.assertIn("renderer", _payload(res))

    def test_failed_render_keeps_the_old_file_and_is_an_error(self):
        # Neither renderer reports a failed write, so an older PNG at the
        # destination must not be mistaken for this export.
        from pymol import exporting
        path = os.path.join(tempfile.mkdtemp(), "out.png")
        with open(path, "wb") as f:
            f.write(b"old image")
        self.addCleanup(setattr, exporting, "_metal_png", exporting._metal_png)
        self.addCleanup(setattr, cmd, "png", cmd.png)
        exporting._metal_png = lambda *a, **k: True     # "rendered", wrote nothing
        cmd.png = lambda *a, **k: None                  # CPU fallback writes nothing
        res = tools.call("export_image", {"path": path, "width": 64,
                                          "height": 48})
        self.assertTrue(res["isError"])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), b"old image")
        self.assertEqual(os.listdir(os.path.dirname(path)), ["out.png"])

    def test_missing_folder_is_an_error(self):
        res = tools.call("export_image",
                         {"path": "/nonexistent-dir-raymol/out.png"})
        self.assertTrue(res["isError"])
        self.assertIn("folder does not exist", res["content"][0]["text"])

    def test_movie_without_frames_says_how_to_make_one(self):
        res = tools.call("export_movie", {"path": "/tmp/x.mp4"})
        self.assertTrue(res["isError"])
        self.assertIn("mset", res["content"][0]["text"])


class TestJobsAndHelp(_NativeCase):
    def test_job_status_lists_jobs(self):
        res = tools.call("job_status", {})
        self.assertFalse(res["isError"], res)
        self.assertIn("prediction", _payload(res))

    def test_unknown_job_is_an_error(self):
        res = tools.call("job_status", {"job_id": "no-such-job"})
        self.assertTrue(res["isError"])

    def test_help_guide_and_topics(self):
        guide = tools.call("raymol_help", {})["content"][0]["text"]
        self.assertIn("RAYMOL FEATURE GUIDE", guide)
        for topic, expect in (("lights", "studio lighting"),
                              ("materials", "frosted_glass"),
                              ("effects", "metal_raytrace"),
                              ("presets", "rembrandt"),
                              ("predictors", "boltz2")):
            res = tools.call("raymol_help", {"topic": topic})
            self.assertFalse(res["isError"], (topic, res))
            self.assertIn(expect, res["content"][0]["text"])

    def test_help_unknown_topic_lists_topics(self):
        res = tools.call("raymol_help", {"topic": "nonsense"})
        self.assertTrue(res["isError"])
        self.assertIn("materials", res["content"][0]["text"])


class TestSessionStateRayMol(_NativeCase):
    def test_reports_rig_effects_and_materials(self):
        cmd.lights("softbox")
        cmd.set("cartoon_material", "marble", "ala")
        res = tools.call("get_session_state", {})
        self.assertFalse(res["isError"], res)
        raymol = json.loads(res["content"][0]["text"])["raymol"]
        self.assertTrue(raymol["lights"]["enabled"])
        self.assertIn("raytrace", raymol["render_effects"])
        self.assertEqual(raymol["materials"], {"ala": {"cartoon": "marble"}})
        self.assertIsInstance(raymol["scenes"], list)


class TestSessionStateMorphJobs(_NativeCase):
    """Morphs (morph_jobs.py) under raymol.morph_jobs: those being built,
    cancelled or failed ones until dismissed, and done ones still loaded."""

    def setUp(self):
        super().setUp()
        from pymol import morph_jobs
        self.mj = morph_jobs
        # the registry outlives reinitialize; give each test its own
        saved = dict(morph_jobs._JOBS)
        morph_jobs._JOBS.clear()
        self.addCleanup(morph_jobs._JOBS.update, saved)
        self.addCleanup(morph_jobs._JOBS.clear)
        cmd.fab("ACDEFGHIK", "src")
        for k in (2, 3):
            cmd.create("src", "src", 1, k)
            cmd.rotate("y", 25 * (k - 1), "src and resi 5-9", k)

    def morph_jobs_state(self):
        res = tools.call("get_session_state", {})
        self.assertFalse(res["isError"], res)
        return json.loads(res["content"][0]["text"])["raymol"]["morph_jobs"]

    def start(self):
        """A morph the test drives (no worker): 3 models, loop, 3 legs."""
        job = self.mj.start_job("src", frames_per_model=4, refinement=0)
        self.addCleanup(self.mj.morph_cancel, "src_morph")
        return job

    def test_none_is_an_empty_list(self):
        self.assertEqual(self.morph_jobs_state(), [])

    def test_a_morph_being_built_reports_its_progress(self):
        job = self.start()
        job.step()
        self.mj.pump()
        self.assertEqual(self.morph_jobs_state(), [
            {"name": "src_morph", "source": "src", "status": "running",
             "progress": 0.333}])

    def test_reading_the_state_lands_nothing(self):
        # Read-only: the app's panel poll lands frames, never this.
        job = self.start()
        job.step()                      # one leg computed, not landed
        self.morph_jobs_state()
        self.assertEqual(cmd.count_states("src_morph"), 1)
        self.assertEqual(job.landed_legs, 0)

    def test_a_done_morph_is_listed_while_it_is_loaded(self):
        self.mj.morph_object("src", frames_per_model=4, refinement=0, async_=0)
        self.assertEqual(self.morph_jobs_state(), [
            {"name": "src_morph", "source": "src", "status": "done",
             "progress": 1.0}])
        cmd.delete("src_morph")
        self.assertEqual(self.morph_jobs_state(), [])

    def test_a_cancelled_morph_is_listed_until_dismissed(self):
        self.start()
        self.mj.morph_cancel("src_morph")
        self.assertEqual(
            [(j["name"], j["source"], j["status"])
             for j in self.morph_jobs_state()],
            [("src_morph", "src", "cancelled")])
        self.mj.morph_dismiss("src_morph")
        self.assertEqual(self.morph_jobs_state(), [])

    def test_a_refused_morph_is_listed_as_an_error(self):
        # Refused before any job existed: still a record, so an agent sees why
        self.addCleanup(setattr, self.mj, "REFUSE_BYTES", None)
        self.mj.REFUSE_BYTES = 10
        with self.assertRaises(pymol.CmdException):
            self.mj.morph_object("src", async_=0)
        jobs = self.morph_jobs_state()
        self.assertEqual([(j["name"], j["source"], j["status"]) for j in jobs],
                         [("src_morph", "src", "error")])
        self.assertIn("Reduce frames per model", jobs[0]["error"])

    def test_a_broken_morph_surface_leaves_the_rest_of_the_state(self):
        def boom():
            raise RuntimeError("broken")
        real = self.mj.pending_objects
        self.mj.pending_objects = boom
        self.addCleanup(setattr, self.mj, "pending_objects", real)
        state = native.raymol_state(cmd)
        self.assertTrue(state["morph_jobs"].startswith("unavailable"))
        self.assertIn("raytrace", state["render_effects"])

    def test_help_serves_the_morph_commands_manuals(self):
        for name in ("morph_object", "morph_cancel", "morph_dismiss"):
            res = tools.call("raymol_help", {"topic": name})
            self.assertFalse(res["isError"], (name, res))
            self.assertIn("DESCRIPTION", res["content"][0]["text"])

    def test_cancel_and_dismiss_manuals_name_the_morph_object(self):
        # An agent guessing `morph_cancel 2kpo` (the source) gets "not being
        # built": the manual must say the argument is the morph's own name.
        for name in ("morph_cancel", "morph_dismiss"):
            text = tools.call("raymol_help", {"topic": name})["content"][0]["text"]
            text = " ".join(text.split())       # the manual wraps its lines
            for part in ("USAGE", "ARGUMENTS", "name = str", "2kpo_morph",
                         "not the source"):
                self.assertIn(part, text, name)

    def test_guide_says_when_to_stop_polling_a_morph(self):
        # "until its status is done" never ends after a cancel or a failure
        from raymol_mcp import guide
        start = guide.GUIDE.index("MORPHS")
        block = " ".join(guide.GUIDE[start:guide.GUIDE.index("\n\n", start)].split())
        self.assertIn("until its status is done, cancelled or error", block)
        # RayMol's own morph, which also morphs through one ensemble
        self.assertIn("state1=0", block)
        self.assertNotIn("stock", block)


class TestHabitNotes(_NativeCase):
    def test_stock_pymol_idioms_get_a_note(self):
        for code in ("ray 800, 600", "set ray_shadows, 1", "set light, [1,1,1]",
                     "cmd.png('/tmp/a.png')", "mpng frame"):
            self.assertTrue(native.habit_notes(code), code)

    def test_ordinary_commands_get_none(self):
        for code in ("show cartoon", "set cartoon_transparency, 0.5",
                     "color red, chain A", "array = 1", "spray = 2",
                     "set metal_raytrace, 1"):
            self.assertEqual(native.habit_notes(code), [], code)

    def test_note_rides_along_with_the_result(self):
        res = tools.call("run_pymol_command",
                         {"command": "set ray_shadows, 0"})
        self.assertFalse(res["isError"], res)
        self.assertEqual(res["content"][0]["text"], "ok")
        self.assertIn("set_render_effects", res["content"][-1]["text"])


if __name__ == "__main__":
    unittest.main()
