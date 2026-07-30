# Copyright (c) 2024-2025 Institute of Information Engineering, Chinese Academy of Sciences
#
# DiveFuzz is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
#
# See the Mulan PSL v2 for more details.

"""
Regression tests for run_dut.py's command line exit codes.

run_dut.py already detected a missing config file and returned 1 from main(),
but the `sys.exit(main())` call was commented out, so the process still exited
0 and callers (CI, scripts, containers) could not detect the failure. These
tests pin the corrected behaviour.

Run with:  python -m unittest discover -s tests
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUN_DUT = REPO_ROOT / "fuzzer" / "run_dut.py"


def run_cli(*args, cwd=None):
    """Invoke run_dut.py as a subprocess and capture its result."""
    return subprocess.run(
        [sys.executable, str(RUN_DUT), *args],
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )


class TestRunDutExitCodes(unittest.TestCase):
    def setUp(self):
        # run_dut.py creates a relative `outputs` directory, so keep the test
        # from writing into the repository.
        self._tmp = tempfile.TemporaryDirectory()
        self.cwd = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_help_succeeds(self):
        result = run_cli("--help", cwd=self.cwd)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--config", result.stdout)

    def test_missing_config_is_non_success(self):
        missing = os.path.join(self.cwd, "does-not-exist.yaml")
        result = run_cli("--config", missing, cwd=self.cwd)

        self.assertNotEqual(
            result.returncode,
            0,
            "a missing config file must produce a non-success exit code; "
            f"got 0 with output:\n{result.stdout}",
        )
        self.assertIn(
            "Config file not found",
            result.stdout,
            "the failure must be understandable to the caller",
        )

    def test_absent_config_argument_is_non_success(self):
        # argparse enforces --config being required; this pins that it stays
        # a usage error rather than a silent success.
        result = run_cli(cwd=self.cwd)
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
