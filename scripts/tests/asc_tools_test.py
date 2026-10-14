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


if __name__ == "__main__":
    unittest.main(verbosity=2)
