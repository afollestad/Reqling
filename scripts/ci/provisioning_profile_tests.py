#!/usr/bin/env python3
from __future__ import annotations

import datetime
import hashlib
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL_PATH = Path(__file__).parent.parent / "lib" / "provisioning_profile.py"
_spec = importlib.util.spec_from_file_location("provisioning_profile", TOOL_PATH)
assert _spec is not None and _spec.loader is not None
tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tool)

NOW = datetime.datetime(2026, 11, 8)
CERTIFICATE = b"a certificate"
CERTIFICATE_SHA1 = hashlib.sha1(CERTIFICATE).hexdigest().upper()
DEVICE = "00006050-001420D40AF9401C"


def profile(*, distribution: bool = False, **changes: object) -> dict:
    """A profile as the portal makes one for Reqling, after `changes`."""
    bundle_id = "com.afollestad.reqling" if distribution else "com.afollestad.reqling.debug"
    entitlements = {
        "com.apple.application-identifier": f"TEAM123456.{bundle_id}",
        "com.apple.developer.team-identifier": "TEAM123456",
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.afollestad.reqling"],
        "com.apple.developer.icloud-services": "*",
        "com.apple.developer.aps-environment": "production" if distribution else "development",
    }
    entitlements.update(changes.pop("entitlements", {}))  # type: ignore[arg-type]
    result: dict = {
        "Name": "Reqling",
        "Platform": ["OSX"],
        "TeamIdentifier": ["TEAM123456"],
        "ExpirationDate": NOW + datetime.timedelta(days=365),
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": entitlements,
    }
    if distribution:
        result["ProvisionsAllDevices"] = True
    else:
        result["ProvisionedDevices"] = [DEVICE]
    result.update(changes)
    return result


def signed(content: dict, directory: Path) -> Path:
    """`content` in a CMS envelope, as the portal delivers a profile, signed by a throwaway certificate."""
    key, certificate = directory / "key.pem", directory / "certificate.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", certificate, "-days", "1",
         "-subj", "/CN=Fixture"],
        check=True,
        capture_output=True,
    )
    source, path = directory / "content.plist", directory / "fixture.provisionprofile"
    source.write_bytes(plistlib.dumps(content))
    subprocess.run(
        ["openssl", "smime", "-sign", "-in", source, "-signer", certificate, "-inkey", key, "-outform", "DER", "-nodetach",
         "-binary", "-out", path],
        check=True,
        capture_output=True,
    )
    return path


class ProblemsTests(unittest.TestCase):
    def check(self, content: dict, *, distribution: bool = False, min_days: int = 0) -> list[str]:
        return tool.problems(
            content,
            bundle_id="com.afollestad.reqling" if distribution else "com.afollestad.reqling.debug",
            certificate=CERTIFICATE_SHA1,
            now=NOW,
            device=None if distribution else DEVICE,
            distribution=distribution,
            min_days=min_days,
        )

    def test_the_portals_profiles_pass(self) -> None:
        self.assertEqual(self.check(profile()), [])
        self.assertEqual(self.check(profile(distribution=True), distribution=True), [])

    def test_a_profile_without_the_container_names_the_fix(self) -> None:
        found = self.check(profile(entitlements={"com.apple.developer.icloud-container-identifiers": []}))

        self.assertEqual(len(found), 1)
        self.assertIn("assign it under iCloud", found[0])

    def test_a_development_profile_cant_sign_a_release(self) -> None:
        found = self.check(profile(entitlements={"com.apple.application-identifier": "TEAM123456.com.afollestad.reqling"}),
                           distribution=True)

        self.assertTrue(any("development profile" in problem for problem in found), found)
        self.assertTrue(any("push environment is development" in problem for problem in found), found)

    def test_the_signing_certificate_device_and_expiry_must_fit(self) -> None:
        found = self.check(profile(
            DeveloperCertificates=[b"another certificate"],
            ProvisionedDevices=["another Mac"],
            ExpirationDate=NOW + datetime.timedelta(days=10),
        ), min_days=30)

        self.assertEqual(len(found), 3, found)

    def test_signed_entitlements_add_the_identifiers_the_profile_grants(self) -> None:
        template = {"com.apple.developer.aps-environment": "development"}

        entitlements = tool.signed_entitlements(profile(), template)

        self.assertEqual(entitlements["com.apple.application-identifier"], "TEAM123456.com.afollestad.reqling.debug")
        self.assertEqual(entitlements["com.apple.developer.team-identifier"], "TEAM123456")
        self.assertEqual(entitlements["com.apple.developer.aps-environment"], "development")


class CommandTests(unittest.TestCase):
    def run_tool(self, *arguments: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-I", str(TOOL_PATH), *map(str, arguments)], capture_output=True, text=True,
                              check=False)

    def test_check_reads_a_profiles_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            good = signed(profile(ExpirationDate=datetime.datetime(2100, 1, 1)), Path(directory))
            arguments = ["check", good, "--bundle-id", "com.afollestad.reqling.debug", "--certificate", CERTIFICATE_SHA1,
                         "--device", DEVICE]

            self.assertEqual(self.run_tool(*arguments).returncode, 0)
            refused = self.run_tool(*arguments[:-1], "another Mac")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("doesn't list this Mac", refused.stderr)

    def test_find_picks_a_usable_profile_and_entitlements_fill_the_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "Profiles"
            folder.mkdir()
            good = signed(profile(ExpirationDate=datetime.datetime(2100, 1, 1)), Path(directory))
            good.rename(folder / "good.provisionprofile")
            (folder / "broken.mobileprovision").write_bytes(b"not a profile")

            found = self.run_tool("find", folder, "--bundle-id", "com.afollestad.reqling.debug", "--certificate",
                                  CERTIFICATE_SHA1, "--device", DEVICE)
            template, output = Path(directory) / "template.plist", Path(directory) / "out.plist"
            template.write_bytes(plistlib.dumps({"com.apple.developer.aps-environment": "development"}))
            filled = self.run_tool("entitlements", folder / "good.provisionprofile", template, output)

            self.assertEqual(found.stdout.strip(), str(folder / "good.provisionprofile"))
            self.assertEqual(filled.returncode, 0, filled.stderr)
            self.assertEqual(plistlib.loads(output.read_bytes())["com.apple.developer.team-identifier"], "TEAM123456")


if __name__ == "__main__":
    unittest.main()
