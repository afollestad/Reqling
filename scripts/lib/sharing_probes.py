#!/usr/bin/env python3
"""Raw CloudKit sharing probes across the two copies `scripts/sharing-e2e.sh launch` runs: the owner on this Mac, the
participant on the other. Each probe does one thing the sharing design depends on and records what the server did, so the
fake CloudKit the tests use (`Tests/ReqlingKitTests/Sync/Support/SyncTestCloud.swift`) can be checked against it.

    sharing_probes.py ENDPOINTS REPORT

ENDPOINTS is the JSON `launch` writes; REPORT is where the findings go, as JSON. A summary prints as each probe ends.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request
from pathlib import Path

# How long a change may take to reach the other side before a probe gives up on it.
PROPAGATION_TIMEOUT = 90.0
POLL_INTERVAL = 3.0


class Side:
    """One copy's MCP server, called as JSON-RPC over HTTP with its bearer token."""

    def __init__(self, name: str, endpoint: dict) -> None:
        self.name = name
        self.url = f"http://127.0.0.1:{endpoint['port']}/mcp"
        self.token = endpoint["token"]
        self.email = endpoint.get("email")
        self.next_id = 1
        self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "sharing-probes", "version": "1"},
        })

    def request(self, method: str, params: dict) -> dict:
        body = json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}).encode()
        self.next_id += 1
        request = urllib.request.Request(self.url, data=body, method="POST", headers={
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        })
        with urllib.request.urlopen(request, timeout=120) as response:
            text = response.read().decode()
        # A streaming answer carries the JSON on its `data:` lines.
        if text.lstrip().startswith("{"):
            reply = json.loads(text)
        else:
            reply = json.loads("".join(line[5:] for line in text.splitlines() if line.startswith("data:")))
        if "error" in reply:
            raise RuntimeError(f"{self.name}: {method} failed: {reply['error']}")
        return reply["result"]

    def call(self, tool: str, **arguments: object) -> dict:
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(f"{self.name}: {tool} failed: {result.get('content')}")
        return result.get("structuredContent") or {}


def wait_for(description: str, attempt) -> object:
    """`attempt()`'s first truthy answer, polled until PROPAGATION_TIMEOUT; `None` when it never came."""
    deadline = time.monotonic() + PROPAGATION_TIMEOUT
    while True:
        answer = attempt()
        if answer:
            return answer
        if time.monotonic() > deadline:
            print(f"  timed out waiting for {description}")
            return None
        time.sleep(POLL_INTERVAL)


def zone_deletion(side: Side, database: str, zone: str) -> dict | None:
    """The deletion of `zone` that `side`'s `database` reports, once it does."""
    def attempt() -> dict | None:
        changes = side.call("probe_changes", database=database)
        return next((deletion for deletion in changes.get("zoneDeletions", []) if deletion["zone"] == zone), None)
    return wait_for(f"{side.name} to see {zone} go", attempt)  # type: ignore[return-value]


def shared(owner: Side, participant: Side, **share: object) -> dict:
    """A probe zone the owner shares as `share` says, accepted by the participant."""
    made = owner.call("probe_share", **share)
    accepted = participant.call("probe_accept", url=made["url"])
    return {**made, **accepted}


def run(owner: Side, participant: Side) -> dict:
    findings: dict = {}

    def record(name: str, value: object) -> None:
        findings[name] = value
        print(f"{name}: {json.dumps(value)}")

    record("identities", {"owner": owner.call("probe_identity"), "participant": participant.call("probe_identity")})
    owner.call("probe_reset")
    participant.call("probe_changes", database="shared")
    owner.call("probe_changes", database="private")
    email = participant.email

    # Invited, read-only, then read-write: what each may do, and how a share record arrives in a fetch.
    for permission in ("readOnly", "readWrite"):
        zone = shared(owner, participant, invite=email, permission=permission)
        record(f"invited_{permission}_accept", {key: zone[key] for key in ("role", "permission", "publicPermission")})
        record(f"invited_{permission}_participant_write", participant.call("probe_write", zone=zone["zone"], owner=zone["owner"]))
        record(f"invited_{permission}_participant_read", participant.call("probe_read", zone=zone["zone"], owner=zone["owner"]))
        record(f"invited_{permission}_owner_fetch", owner.call("probe_changes", database="private"))
        record(f"invited_{permission}_participant_fetch", participant.call("probe_changes", database="shared"))

    # A read-only administrator: may it raise the link's permission, or its own?
    zone = shared(owner, participant, invite=email, permission="readOnly", canInvite=True)
    record("admin_readOnly_accept", {key: zone[key] for key in ("role", "permission")})
    record("admin_readOnly_raise_link", participant.call(
        "probe_update_share", zone=zone["zone"], owner=zone["owner"], publicPermission="readWrite"))
    record("admin_readOnly_raise_self", participant.call(
        "probe_update_share", zone=zone["zone"], owner=zone["owner"], invite=email, permission="readWrite", canInvite=True))
    record("admin_readOnly_write_after", participant.call("probe_write", zone=zone["zone"], owner=zone["owner"]))

    # Anyone with the link: the role it gives, and whether encrypted fields read.
    for permission in ("readOnly", "readWrite"):
        zone = shared(owner, participant, publicPermission=permission)
        record(f"link_{permission}_accept", {key: zone[key] for key in ("role", "permission", "publicPermission")})
        record(f"link_{permission}_participant_read", participant.call("probe_read", zone=zone["zone"], owner=zone["owner"]))
        record(f"link_{permission}_participant_write", participant.call("probe_write", zone=zone["zone"], owner=zone["owner"]))

    # Losing access, each way, as the participant's shared database reports it.
    participant.call("probe_changes", database="shared")
    zone = shared(owner, participant, invite=email, permission="readWrite")
    owner.call("probe_remove_participant", zone=zone["zone"], email=email)
    record("removed_participant_sees", zone_deletion(participant, "shared", zone["zone"]))

    zone = shared(owner, participant, invite=email, permission="readWrite")
    owner.call("probe_stop_sharing", zone=zone["zone"])
    record("stopped_sharing_participant_sees", zone_deletion(participant, "shared", zone["zone"]))
    record("stopped_sharing_owner_fetch", owner.call("probe_changes", database="private"))

    zone = shared(owner, participant, invite=email, permission="readWrite")
    owner.call("probe_delete_zone", zone=zone["zone"])
    record("deleted_zone_participant_sees", zone_deletion(participant, "shared", zone["zone"]))

    zone = shared(owner, participant, invite=email, permission="readWrite")
    record("leave", participant.call("probe_leave", zone=zone["zone"], owner=zone["owner"]))
    record("left_participant_sees", zone_deletion(participant, "shared", zone["zone"]))
    record("left_owner_fetch", owner.call("probe_changes", database="private"))

    owner.call("probe_reset")
    return findings


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    endpoints = json.loads(Path(arguments[0]).read_text())
    if not endpoints["participant"].get("email"):
        print("error: the participant's email isn't known; run ./scripts/sharing-e2e.sh pair", file=sys.stderr)
        return 1
    findings = run(Side("owner", endpoints["owner"]), Side("participant", endpoints["participant"]))
    Path(arguments[1]).write_text(json.dumps(findings, indent=2, sort_keys=True))
    print(f"Wrote {arguments[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
