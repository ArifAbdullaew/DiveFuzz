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
Regression tests for the executor -> generator configuration bridge.

fuzzer/executor/divefuzz_adapter.py builds a DiveFuzzArgConfig and hands it to
generator/config/config_manager.setup_config(), which reads attributes off it
directly. DiveFuzzArgConfig was missing stateful_xor_cache, bug_filter_enable
and jump_enable, so `run_dut.py --config <yaml>` with `input: divefuzz` died
with AttributeError before generating a single seed.

These tests pin that every attribute Config.__init__ touches exists, and that
the executor defaults match the standalone generator CLI defaults.

Run with:  python -m unittest discover -s tests
"""

import ast
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FUZZER_DIR = REPO_ROOT / "fuzzer"
CONFIG_MANAGER = FUZZER_DIR / "generator" / "config" / "config_manager.py"

sys.path.insert(0, str(FUZZER_DIR))

from config.divefuzz_config import DiveFuzzArgConfig  # noqa: E402


def attributes_read_from_args():
    """Every `args.<name>` read inside config_manager.Config.__init__."""
    tree = ast.parse(CONFIG_MANAGER.read_text())
    names = set()

    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "Config":
            for sub in ast.walk(node):
                if (
                    isinstance(sub, ast.Attribute)
                    and isinstance(sub.value, ast.Name)
                    and sub.value.id == "args"
                ):
                    names.add(sub.attr)
    return names


class TestDiveFuzzArgConfig(unittest.TestCase):
    def test_supplies_every_attribute_config_manager_reads(self):
        cfg = DiveFuzzArgConfig()
        missing = sorted(
            name
            for name in attributes_read_from_args()
            # mutate_time is read via getattr() with a default, so it is optional.
            if name != "mutate_time" and not hasattr(cfg, name)
        )
        self.assertEqual(
            missing,
            [],
            "DiveFuzzArgConfig is missing attributes that "
            "generator/config/config_manager.py reads unconditionally: "
            f"{missing}",
        )

    def test_feature_toggle_defaults_match_generator_cli(self):
        # generator/config/cli_parser.py sets all three to True by default.
        cfg = DiveFuzzArgConfig()
        self.assertTrue(cfg.stateful_xor_cache)
        self.assertTrue(cfg.bug_filter_enable)
        self.assertTrue(cfg.jump_enable)

    def test_setup_config_accepts_an_executor_built_config(self):
        from generator.config.config_manager import setup_config

        cfg = setup_config(
            DiveFuzzArgConfig(
                generate=True,
                template_type="xiangshan",
                allowed_ext_name="base",
                architecture="xs",
                instr_number=4,
                seeds=1,
                max_workers=1,
            )
        )
        self.assertTrue(cfg.generate_enable)
        self.assertTrue(cfg.stateful_xor_cache)
        self.assertTrue(cfg.bug_filter_enable)
        self.assertTrue(cfg.jump_enable)


if __name__ == "__main__":
    unittest.main()
