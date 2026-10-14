"""Offline unit tests for the App Store Connect helpers used by the
self-hosted beta pipeline. No network, no PyJWT: every ASC call goes through
an injected fake."""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import asc_api  # noqa: E402
import asc_next_build_number as nbn  # noqa: E402


def fake_get(pages):
    calls = []

    def get(path):
        calls.append(path)
        return pages[path]

    get.calls = calls
    return get


def page(*versions, next_url=None):
    return {"data": [{"attributes": {"version": v}} for v in versions],
            "links": {"next": next_url} if next_url else {}}


FIRST = nbn.PAGE.format(app="APP")


class LoadEnvTest(unittest.TestCase):
    def test_export_quotes_comments(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write('# comment\n\nexport ASC_KEY_ID="KID123"\nASC_ISSUER=\'iss-uuid\'\nASC_VENDOR=94460417\n')
        try:
            env = asc_api.load_env(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(env["ASC_KEY_ID"], "KID123")
        self.assertEqual(env["ASC_ISSUER"], "iss-uuid")
        self.assertEqual(env["ASC_VENDOR"], "94460417")


class NextBuildNumberTest(unittest.TestCase):
    def test_max_across_pages_plus_one(self):
        get = fake_get({FIRST: page("203", "362", next_url="https://x/p2"),
                        "https://x/p2": page("361", "204")})
        self.assertEqual(nbn.next_build_number(nbn.iter_build_pages(get, "APP")), 363)
        self.assertEqual(get.calls, [FIRST, "https://x/p2"])

    def test_numeric_not_lexicographic(self):
        # As strings "99" > "362"; as build numbers it is not.
        self.assertEqual(nbn.next_build_number([page("99", "362", "1000")]), 1001)

    def test_dotted_and_non_numeric_versions(self):
        self.assertEqual(nbn.build_number("32.190"), 32)
        self.assertIsNone(nbn.build_number("beta"))
        self.assertIsNone(nbn.build_number(""))
        self.assertEqual(nbn.next_build_number([page("beta", "32.190", "40")]), 41)

    def test_no_builds_refuses(self):
        with self.assertRaises(ValueError):
            nbn.next_build_number([page()])
        with self.assertRaises(ValueError):
            nbn.next_build_number([page("beta", "")])

    def test_import_does_not_need_jwt(self):
        code = ("import sys; sys.path.insert(0, %r); "
                "import asc_next_build_number; print('jwt' in sys.modules)") % SCRIPTS
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "False")


import xcode_cloud_beta_workflows as xcw  # noqa: E402


class FakeASC:
    """Minimal ciWorkflows store. ignore_writes simulates ASC accepting a
    PATCH without applying it."""

    def __init__(self, enabled=True, ignore_writes=False):
        self.state = {wf: enabled for wf in xcw.WORKFLOWS.values()}
        self.ignore_writes = ignore_writes
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        wf = path.rsplit("/", 1)[-1]
        if method == "PATCH" and not self.ignore_writes:
            self.state[wf] = body["data"]["attributes"]["isEnabled"]
        return {"data": {"id": wf, "attributes": {"isEnabled": self.state[wf]}}}


class XcodeCloudWorkflowsTest(unittest.TestCase):
    def test_patch_body_shape(self):
        self.assertEqual(xcw.patch_body("ID", False),
                         {"data": {"type": "ciWorkflows", "id": "ID",
                                   "attributes": {"isEnabled": False}}})

    def test_disable_both_and_read_back(self):
        fake, lines = FakeASC(enabled=True), []
        self.assertEqual(xcw.run("disable", fake, lines.append), 0)
        self.assertEqual(set(fake.state.values()), {False})
        patched = [p for m, p, _ in fake.calls if m == "PATCH"]
        self.assertEqual(sorted(patched), sorted(f"/v1/ciWorkflows/{w}" for w in xcw.WORKFLOWS.values()))
        self.assertTrue(all("isEnabled=False" in l for l in lines))

    def test_status_never_writes(self):
        fake = FakeASC(enabled=True)
        self.assertEqual(xcw.run("status", fake, lambda _: None), 0)
        self.assertFalse([c for c in fake.calls if c[0] != "GET"])

    def test_write_not_applied_is_an_error(self):
        fake, lines = FakeASC(enabled=True, ignore_writes=True), []
        self.assertEqual(xcw.run("disable", fake, lines.append), 1)
        self.assertTrue(any(l.startswith("ERROR") for l in lines))

    def test_unknown_command(self):
        with self.assertRaises(SystemExit):
            xcw.run("delete", FakeASC(), lambda _: None)


import asc_wait_build_valid as wbv  # noqa: E402


class FakeClock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def now(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


def states_get(states):
    """Each call returns the next processingState; None = build not listed yet."""
    seq, calls = list(states), []

    def get(path):
        calls.append(path)
        st = seq.pop(0) if len(seq) > 1 else seq[0]
        data = [] if st is None else [{"attributes": {"version": "363", "processingState": st}}]
        return {"data": data}

    get.calls = calls
    return get


class WaitBuildValidTest(unittest.TestCase):
    def wait(self, get, clock, platform="iOS", timeout=600):
        lines = []
        rc = wbv.wait_valid(get, "APP", 363, platform, timeout_s=timeout, interval_s=30,
                            sleep=clock.sleep, now=clock.now, out=lines.append)
        return rc, lines

    def test_processing_then_valid(self):
        clock, get = FakeClock(), states_get([None, "PROCESSING", "PROCESSING", "VALID"])
        rc, _ = self.wait(get, clock)
        self.assertEqual(rc, 0)
        self.assertEqual(clock.sleeps, [30, 30, 30])

    def test_query_filters_build_and_platform(self):
        get = states_get(["VALID"])
        self.wait(get, FakeClock(), platform="macOS")
        self.assertIn("filter[app]=APP", get.calls[0])
        self.assertIn("filter[version]=363", get.calls[0])
        self.assertIn("filter[preReleaseVersion.platform]=MAC_OS", get.calls[0])
        get = states_get(["VALID"])
        self.wait(get, FakeClock(), platform="iOS")
        self.assertIn("filter[preReleaseVersion.platform]=IOS", get.calls[0])

    def test_invalid_fails_without_waiting_out_the_timeout(self):
        clock = FakeClock()
        rc, lines = self.wait(states_get(["PROCESSING", "INVALID"]), clock)
        self.assertEqual(rc, 1)
        self.assertEqual(clock.sleeps, [30])
        self.assertTrue(any("INVALID" in l for l in lines))

    def test_failed_state_fails(self):
        rc, _ = self.wait(states_get(["FAILED"]), FakeClock())
        self.assertEqual(rc, 1)

    def test_timeout_fails(self):
        clock = FakeClock()
        rc, lines = self.wait(states_get(["PROCESSING"]), clock, timeout=120)
        self.assertEqual(rc, 1)
        self.assertLessEqual(clock.t, 150)
        self.assertTrue(any("timed out" in l for l in lines))

    def test_unknown_platform_rejected(self):
        with self.assertRaises(ValueError):
            self.wait(states_get(["VALID"]), FakeClock(), platform="tvOS")


if __name__ == "__main__":
    unittest.main(verbosity=2)
