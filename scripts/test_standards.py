import re
import tempfile
import unittest
from pathlib import Path

import check_confidential as cc
import check_standards as cs

GOOD_README = "# S\n\nsummary\n\n## Prerequisites\n\n## Quick start\n"


def make_solution(root: Path, name: str, files: dict[str, str]) -> Path:
    sol = root / name
    for rel, text in files.items():
        (sol / rel).parent.mkdir(parents=True, exist_ok=True)
        (sol / rel).write_text(text)
    return sol


class SolutionViolations(unittest.TestCase):
    def check(self, files):
        with tempfile.TemporaryDirectory() as d:
            return cs.solution_violations(make_solution(Path(d), "s", files))

    def test_clean(self):
        self.assertEqual(self.check({"README.md": GOOD_README, "run.sh": "x"}), set())

    def test_banned_file_any_depth_and_case(self):
        v = self.check({"README.md": GOOD_README, "run.sh": "x", "sub/Claude.md": ""})
        self.assertEqual(v, {"banned-file:sub/Claude.md"})

    def test_banned_dir(self):
        v = self.check({"README.md": GOOD_README, "run.sh": "x", ".claude/settings.json": "{}"})
        self.assertIn("banned-file:.claude/", v)

    def test_markdown_only(self):
        self.assertEqual(self.check({"README.md": GOOD_README}), {"no-artifacts"})

    def test_missing_sections_and_aliases(self):
        v = self.check({"README.md": "# S\n## Usage\n", "run.sh": "x"})
        self.assertEqual(v, {"missing-section:prerequisites"})

    def test_missing_readme(self):
        self.assertEqual(self.check({"run.sh": "x"}), {"missing-readme"})


class Touched(unittest.TestCase):
    sols = ["cat/a", "cat/grp/b", "cat/ab"]

    def test_maps_nested_paths_to_solution(self):
        self.assertEqual(cs.touched_solutions(["cat/grp/b/x/y.sh", "README.md"], self.sols), {"cat/grp/b"})

    def test_prefix_of_sibling_name_not_matched(self):
        self.assertEqual(cs.touched_solutions(["cat/ab/x"], self.sols), {"cat/ab"})


class Grandfathering(unittest.TestCase):
    base = {"old": ["no-artifacts"]}

    def test_untouched_baselined_tolerated(self):
        self.assertEqual(cs.enforced("old", {"no-artifacts"}, self.base, set()), set())

    def test_new_violation_in_baselined_still_fails(self):
        self.assertEqual(cs.enforced("old", {"no-artifacts", "banned-file:CLAUDE.md"}, self.base, set()),
                         {"banned-file:CLAUDE.md"})

    def test_touched_baselined_must_be_clean(self):
        self.assertEqual(cs.enforced("old", {"no-artifacts"}, self.base, {"old"}), {"no-artifacts"})

    def test_unlisted_solution_gets_no_grace(self):
        self.assertEqual(cs.enforced("new", {"no-artifacts"}, self.base, set()), {"no-artifacts"})


class Confidential(unittest.TestCase):
    pats = [re.compile(r"internal[ -]only", re.I), re.compile(r"[\w.+-]+@crusoe(energy)?\.(ai|com)", re.I)]

    def scan(self, files):
        with tempfile.TemporaryDirectory() as d:
            for rel, data in files.items():
                (Path(d) / rel).write_bytes(data)
            return cc.scan(Path(d), list(files), self.pats)

    def test_hit_reports_file_and_line(self):
        hits = self.scan({"a.md": b"ok\nINTERNAL ONLY notes\n"})
        self.assertEqual(len(hits), 1)
        self.assertTrue(hits[0].startswith("a.md:2:"))

    def test_staff_email(self):
        self.assertEqual(len(self.scan({"a.md": b"mail jane@crusoeenergy.com"})), 1)

    def test_public_host_allowed(self):
        self.assertEqual(self.scan({"a.md": b"https://s3.crusoe.ai"}), [])

    def test_binary_skipped(self):
        self.assertEqual(self.scan({"a.png": b"\xff\xfe\x00internal only"}), [])

    def shipped(self, text):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.md").write_text(text)
            return cc.scan(Path(d), ["a.md"], cc.load_patterns(cc.DENYLIST))

    def test_shipped_flags_staff_email_and_marker(self):
        self.assertEqual(len(self.shipped("jane@crusoeenergy.com")), 1)
        self.assertEqual(len(self.shipped("this is Internal Use Only")), 1)

    def test_shipped_allows_placeholders(self):
        for ok in ("user@crusoeenergy.com", "YOUR_EMAIL@crusoe.ai", "support@crusoe.ai",
                   "an internal-only deployment", "https://s3.crusoe.ai"):
            self.assertEqual(self.shipped(ok), [], ok)

    def test_scripts_dir_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "scripts").mkdir()
            (Path(d) / "scripts/x.py").write_text("company confidential")
            self.assertEqual(cc.scan(Path(d), ["scripts/x.py"], cc.load_patterns(cc.DENYLIST)), [])


if __name__ == "__main__":
    unittest.main()
