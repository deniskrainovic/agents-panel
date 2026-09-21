#!/usr/bin/env python3
"""Exercise the version command in an isolated release checkout."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/version.py"
        shutil.copy2(Path(__file__).resolve().parent.parent / "scripts/version.py", self.script)
        self.metadata = self.root / "version.json"
        self.metadata.write_text('{"version":"1.0.9","build":12}\n')

    def run_command(self, *args):
        return subprocess.run([sys.executable, str(self.script), *args], capture_output=True, text=True)

    def test_bump_updates_both_values_and_matching_tag_passes(self):
        result = self.run_command("--set", "1.0.10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.metadata.read_text()), {"version": "1.0.10", "build": 13})
        self.assertEqual(self.run_command("--tag", "v1.0.10").returncode, 0)
        self.assertEqual(self.run_command("--field", "build").stdout.strip(), "13")

    def test_wrong_tag_fails(self):
        for tag in ["v1.0.10", "1.0.9", "v1.0.9-rc1", "v1.0.9\n"]:
            with self.subTest(tag=tag):
                self.assertNotEqual(self.run_command("--tag", tag).returncode, 0)

    def test_bad_or_nonincreasing_bumps_leave_file_unchanged(self):
        original = self.metadata.read_bytes()
        for version in ["1.0.9", "1.0.8", "0.9.99", "v1.0.10", "1.0", "1.01.0", "1.0.10-rc1", "1.0.10\n", "<xml>"]:
            with self.subTest(version=version):
                self.assertNotEqual(self.run_command("--set", version).returncode, 0)
                self.assertEqual(self.metadata.read_bytes(), original)

    def test_malformed_metadata_fails(self):
        for contents in ['{}', 'null', '{"version":"1.0.9","build":true}', '{"version":"1.0.9","build":0}', 'broken']:
            with self.subTest(contents=contents):
                self.metadata.write_text(contents)
                self.assertNotEqual(self.run_command().returncode, 0)


if __name__ == "__main__":
    unittest.main()
