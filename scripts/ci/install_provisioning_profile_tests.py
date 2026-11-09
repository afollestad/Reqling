#!/usr/bin/env python3
from __future__ import annotations

import base64
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from provisioning_profile_tests import profile, signed

SCRIPT_PATH = Path(__file__).with_name("install-provisioning-profile.sh")


class InstallProvisioningProfileTests(unittest.TestCase):
    def run_script(self, secret: str, temp: Path) -> tuple[subprocess.CompletedProcess[str], Path]:
        github_env = temp / "github-env"
        github_env.write_text("")
        environment = dict(os.environ, MACOS_PROVISIONING_PROFILE_BASE64=secret, RUNNER_TEMP=str(temp), GITHUB_ENV=str(github_env))
        result = subprocess.run([str(SCRIPT_PATH)], capture_output=True, text=True, check=False, env=environment)
        return result, github_env

    def test_a_profile_lands_in_runner_temp_for_the_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            fixture = signed(profile(distribution=True), temp)
            secret = base64.b64encode(fixture.read_bytes()).decode()

            result, github_env = self.run_script(secret, temp)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            installed = temp / "Reqling.provisionprofile"
            self.assertEqual(github_env.read_text(), f"PROVISIONING_PROFILE={installed}\n")
            self.assertEqual(installed.read_bytes(), fixture.read_bytes())
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_anything_else_fails_without_leaving_a_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            secret = base64.b64encode(b"not a profile").decode()

            result, github_env = self.run_script(secret, temp)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((temp / "Reqling.provisionprofile").exists())
            self.assertEqual(github_env.read_text(), "")
            self.assertIn("set-provisioning-profile-secret.sh", result.stdout)
            self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
