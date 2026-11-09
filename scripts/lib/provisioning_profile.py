#!/usr/bin/env python3
"""Provisioning profiles for iCloud sync, as `scripts/build.sh`, `scripts/set-provisioning-profile-secret.sh`, and
`scripts/ci/verify-release-app.sh` check them.

macOS honors iCloud and push entitlements only when the embedded profile allows them, and refuses to launch an app
that claims one its profile doesn't, so every check here runs before signing rather than leaving it to a launch.

    check PROFILE --bundle-id ID --certificate SHA1 [--device UDID] [--distribution] [--min-days N]
    find DIRECTORY --bundle-id ID --certificate SHA1 --device UDID
    entitlements PROFILE TEMPLATE OUTPUT
    verify-app APP --team TEAM --template TEMPLATE [--min-days N]
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

CONTAINER = "iCloud.com.afollestad.reqling"
# The entitlements `problems` confirms a profile grants, besides the identifiers; a template entitlement outside these
# would pass the check and then stop the app launching (`provisioning_profile_tests.py` keeps them in step).
CHECKED_ENTITLEMENTS = {
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.developer.aps-environment",
    "com.apple.developer.icloud-container-environment",
}
APPLICATION_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"
SERVICES = "com.apple.developer.icloud-services"
PUSH = "com.apple.developer.aps-environment"


def decode(path: Path) -> dict:
    """The profile's property list, from its CMS envelope."""
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"{path} is not a provisioning profile")
    return plistlib.loads(result.stdout)


def team(profile: dict) -> str | None:
    teams = profile.get("TeamIdentifier") or []
    return teams[0] if teams else None


def problems(
    profile: dict,
    *,
    bundle_id: str,
    certificate: str,
    now: datetime.datetime,
    device: str | None = None,
    distribution: bool = False,
    min_days: int = 0,
) -> list[str]:
    """Why `profile` can't sign `bundle_id` with `certificate` for iCloud sync; empty when it can."""
    entitlements = profile.get("Entitlements") or {}
    found: list[str] = []
    if "OSX" not in (profile.get("Platform") or []):
        found.append("it isn't a macOS profile")
    expected_id = f"{team(profile)}.{bundle_id}"
    if entitlements.get(APPLICATION_IDENTIFIER) != expected_id:
        found.append(f"it's for {entitlements.get(APPLICATION_IDENTIFIER)}, not {expected_id}")
    certificates = {hashlib.sha1(der).hexdigest().upper() for der in profile.get("DeveloperCertificates") or []}
    if certificate.upper() not in certificates:
        found.append("it doesn't include the signing certificate; regenerate it with that certificate")
    expiry = profile.get("ExpirationDate")
    if expiry is None or expiry <= now:
        found.append(f"it expired {expiry}")
    elif expiry <= now + datetime.timedelta(days=min_days):
        found.append(f"it expires {expiry}, within {min_days} days")
    if distribution:
        if profile.get("ProvisionedDevices") or not profile.get("ProvisionsAllDevices"):
            found.append("it's a development profile; releases need a Developer ID one")
    elif device is not None and device not in (profile.get("ProvisionedDevices") or []):
        found.append(f"it doesn't list this Mac ({device}); add it in Devices, then regenerate the profile")
    if CONTAINER not in (entitlements.get(CONTAINERS) or []):
        found.append(f"its App ID has no {CONTAINER}: assign it under iCloud, save the App ID, then regenerate the profile")
    services = entitlements.get(SERVICES)
    if services != "*" and "CloudKit" not in (services or []):
        found.append("its App ID doesn't include CloudKit")
    push = "production" if distribution else "development"
    if entitlements.get(PUSH) != push:
        found.append(f"its push environment is {entitlements.get(PUSH)}, expected {push}; enable Push Notifications on the App ID")
    environments = entitlements.get("com.apple.developer.icloud-container-environment")
    environments = [environments] if isinstance(environments, str) else (environments or [])
    if distribution and "Production" not in environments:
        found.append("it doesn't allow CloudKit's Production environment")
    return found


def signed_entitlements(profile: dict, template: dict) -> dict:
    """`template` with the application and team identifiers the profile grants."""
    entitlements = dict(template)
    entitlements[APPLICATION_IDENTIFIER] = (profile.get("Entitlements") or {}).get(APPLICATION_IDENTIFIER)
    entitlements[TEAM_IDENTIFIER] = team(profile)
    return entitlements


def utc_now() -> datetime.datetime:
    # `plistlib` reads profile dates as naive UTC.
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


def code_entitlements(path: Path) -> dict:
    """The entitlements `path` is signed with; empty when it has none."""
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)], capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"couldn't read the signature of {path.name}")
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def leaf_certificate(path: Path) -> str:
    """The SHA-1 of the certificate that signed `path`."""
    with tempfile.TemporaryDirectory() as directory:
        prefix = Path(directory) / "certificate"
        subprocess.run(["codesign", "-d", f"--extract-certificates={prefix}", str(path)], capture_output=True, check=True)
        return hashlib.sha1((Path(directory) / "certificate0").read_bytes()).hexdigest().upper()


def verify_app(app: Path, *, expected_team: str, template: dict, min_days: int) -> list[str]:
    """Why a release bundle's entitlements or profile aren't exactly what it should ship with; empty when they are."""
    profile_path = app / "Contents" / "embedded.provisionprofile"
    if not profile_path.is_file():
        return ["the app embeds no provisioning profile"]
    profile = decode(profile_path)
    found: list[str] = []
    if team(profile) != expected_team:
        found.append(f"its profile is for team {team(profile)}, not {expected_team}")
    executable = app / "Contents" / "MacOS" / "Reqling"
    found += problems(
        profile,
        bundle_id="com.afollestad.reqling",
        certificate=leaf_certificate(app),
        now=utc_now(),
        distribution=True,
        min_days=min_days,
    )
    expected = signed_entitlements(profile, template)
    actual = code_entitlements(app)
    if actual != expected:
        found.append(f"the app's entitlements are {sorted(actual)} with {actual}, expected exactly {expected}")
    for helper in sorted((app / "Contents" / "MacOS").iterdir()):
        if helper != executable and code_entitlements(helper):
            found.append(f"{helper.name} has entitlements; helpers get none")
    return found


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("profile", type=Path)
    find = commands.add_parser("find")
    find.add_argument("directory", type=Path)
    for command in (check, find):
        command.add_argument("--bundle-id", required=True)
        command.add_argument("--certificate", required=True)
        command.add_argument("--device")
    check.add_argument("--distribution", action="store_true")
    check.add_argument("--min-days", type=int, default=0)
    entitlements = commands.add_parser("entitlements")
    entitlements.add_argument("profile", type=Path)
    entitlements.add_argument("template", type=Path)
    entitlements.add_argument("output", type=Path)
    verify = commands.add_parser("verify-app")
    verify.add_argument("app", type=Path)
    verify.add_argument("--team", required=True)
    verify.add_argument("--template", type=Path, required=True)
    verify.add_argument("--min-days", type=int, default=30)
    options = parser.parse_args(arguments)

    try:
        if options.command == "check":
            found = problems(
                decode(options.profile),
                bundle_id=options.bundle_id,
                certificate=options.certificate,
                now=utc_now(),
                device=options.device,
                distribution=options.distribution,
                min_days=options.min_days,
            )
            for problem in found:
                print(f"error: {options.profile.name}: {problem}", file=sys.stderr)
            return 1 if found else 0
        if options.command == "find":
            # The usable profile that lasts longest, among those Xcode and the portal leave in the folder.
            candidates = sorted(options.directory.glob("*.mobileprovision")) + sorted(options.directory.glob("*.provisionprofile"))
            usable = []
            for path in candidates:
                try:
                    profile = decode(path)
                except ValueError:
                    continue
                if not problems(profile, bundle_id=options.bundle_id, certificate=options.certificate, now=utc_now(), device=options.device):
                    usable.append((profile["ExpirationDate"], path))
            if not usable:
                return 1
            print(max(usable)[1])
            return 0
        if options.command == "entitlements":
            template = plistlib.loads(options.template.read_bytes())
            options.output.write_bytes(plistlib.dumps(signed_entitlements(decode(options.profile), template)))
            return 0
        found = verify_app(
            options.app,
            expected_team=options.team,
            template=plistlib.loads(options.template.read_bytes()),
            min_days=options.min_days,
        )
        for problem in found:
            print(f"error: {problem}", file=sys.stderr)
        return 1 if found else 0
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
