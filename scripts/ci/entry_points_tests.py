#!/usr/bin/env python3
from __future__ import annotations

import os
import unittest
from pathlib import Path

CI_DIRECTORY = Path(__file__).parent
SCRIPTS_DIRECTORY = CI_DIRECTORY.parent


def entry_points() -> list[Path]:
    """The scripts the workflows and `RELEASING.md` run directly, by path."""
    scripts = [path for path in CI_DIRECTORY.iterdir() if path.suffix in (".sh", ".py") and not path.name.endswith("_tests.py")]
    return sorted(scripts) + [SCRIPTS_DIRECTORY / "set-certificate-secrets.sh"]


class EntryPointsTests(unittest.TestCase):
    """The workflows run each script by path, so one committed without its executable bit fails only when
    its step first runs, which for the tag and release steps is the first publish."""

    def test_every_entry_point_is_executable(self) -> None:
        for path in entry_points():
            with self.subTest(script=path.name):
                self.assertTrue(os.access(path, os.X_OK), f"{path} is not executable")

    def test_every_entry_point_declares_its_interpreter(self) -> None:
        for path in entry_points():
            with self.subTest(script=path.name):
                first_line = path.read_text(encoding="utf-8").splitlines()[0]
                expected = "#!/usr/bin/env python3" if path.suffix == ".py" else "#!/bin/bash"
                self.assertEqual(first_line, expected)


if __name__ == "__main__":
    unittest.main()
