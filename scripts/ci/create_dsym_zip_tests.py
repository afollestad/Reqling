#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("create-dsym-zip.sh")
# Mach-O binaries present on every macOS machine, standing in for builds with different UUIDs. The
# script only reads their `LC_UUID`, so any distinct binaries work.
SHIPPED_BINARIES = {
    "Reqling": Path("/bin/ls"),
    "ReqlingPKCS12Probe": Path("/bin/cat"),
    "ReqlingScriptRunner": Path("/bin/echo"),
}
OTHER_BUILD_BINARY = Path("/bin/pwd")


class CreateDsymZipTests(unittest.TestCase):
    """A dSYM that does not match the shipped binary symbolicates nothing, and the mismatch surfaces
    only when someone needs a crash report, long after the runner that built it is gone."""

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.export_path = root / "export"
        self.release_path = root / "release"
        self.github_output = root / "github_output"
        self.github_output.touch()
        macos = self.export_path / "Reqling.app" / "Contents" / "MacOS"
        macos.mkdir(parents=True)
        for name, binary in SHIPPED_BINARIES.items():
            shutil.copy(binary, macos / name)
            dwarf = self.dsym(name) / "Contents" / "Resources" / "DWARF"
            dwarf.mkdir(parents=True)
            shutil.copy(binary, dwarf / name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def dsym(self, name: str) -> Path:
        bundle = "Reqling.app.dSYM" if name == "Reqling" else f"{name}.dSYM"
        return self.export_path / "dSYMs" / bundle

    def binary(self, name: str) -> Path:
        return self.export_path / "Reqling.app" / "Contents" / "MacOS" / name

    def run_script(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            EXPORT_PATH=str(self.export_path),
            RELEASE_PATH=str(self.release_path),
            APP_NAME="Reqling",
            GITHUB_OUTPUT=str(self.github_output),
        )
        return subprocess.run([str(SCRIPT_PATH)], check=False, capture_output=True, text=True, env=environment)

    def outputs(self) -> dict[str, str]:
        entries = {}
        for line in self.github_output.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            entries[key] = value
        return entries

    def test_packages_every_dsym_at_the_zip_root_when_every_slice_matches(self) -> None:
        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        zip_path = Path(self.outputs()["dsym_path"])
        self.assertEqual(zip_path.name, "Reqling.dSYMs.zip")
        names = zipfile.ZipFile(zip_path).namelist()
        # Each bundle keeps its name at the top, so an extracted asset is a dSYM `atos -o` accepts.
        self.assertIn("Reqling.app.dSYM/Contents/Resources/DWARF/Reqling", names)
        self.assertIn("ReqlingPKCS12Probe.dSYM/Contents/Resources/DWARF/ReqlingPKCS12Probe", names)
        self.assertIn("ReqlingScriptRunner.dSYM/Contents/Resources/DWARF/ReqlingScriptRunner", names)
        self.assertFalse([name for name in names if name.startswith("dSYMs/")])

    def test_rejects_a_dsym_from_a_different_build(self) -> None:
        for name in SHIPPED_BINARIES:
            with self.subTest(executable=name):
                shutil.copy(OTHER_BUILD_BINARY, self.binary(name))

                result = self.run_script()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"shipped {name} slice", result.stderr)
                self.assertFalse(self.release_path.exists())
                shutil.copy(SHIPPED_BINARIES[name], self.binary(name))

    def test_rejects_an_executable_without_a_dsym(self) -> None:
        # A helper added to the bundle without its dSYM must fail too, not just the app.
        for name in SHIPPED_BINARIES:
            with self.subTest(executable=name):
                moved = self.dsym(name).with_name("moved")
                self.dsym(name).rename(moved)

                result = self.run_script()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"has no dSYM for {name}", result.stderr)
                moved.rename(self.dsym(name))

    def test_rejects_an_unreadable_binary_rather_than_passing_vacuously(self) -> None:
        # An empty UUID list would walk the slice comparison zero times and call that a pass.
        self.binary("ReqlingScriptRunner").write_text("not a Mach-O\n", encoding="utf-8")

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no UUIDs", result.stderr)
        self.assertFalse(self.release_path.exists())

    def test_rejects_a_bundle_without_executables(self) -> None:
        for name in SHIPPED_BINARIES:
            self.binary(name).unlink()

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no executables", result.stderr)


if __name__ == "__main__":
    unittest.main()
