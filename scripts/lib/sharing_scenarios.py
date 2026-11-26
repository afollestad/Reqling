#!/usr/bin/env python3
"""Sharing scenarios across the two copies `scripts/sharing-e2e.sh launch` runs: the owner on this Mac, the participant
on the other. Each scenario shares real projects through the harness's tools (`MCPSharingHarnessTools`), which take
the app's own paths, syncs both copies until what it expects holds, and then checks what neither may ever see: the
owner's secret values on the participant, or the other way round. The fake-CloudKit tests cover the same ground
(`Tests/ReqlingKitTests/Sync/LibrarySyncTests+Sharing.swift`); these show what real CloudKit does.

    sharing_scenarios.py reset ENDPOINTS
    sharing_scenarios.py run ENDPOINTS REPORT [--take-focus] [SCENARIO ...]

ENDPOINTS is the JSON `launch` writes; REPORT is where the results go, as JSON. `run` runs every scenario unless named,
and with --take-focus brings the owner's copy forward too, as it does the participant's.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import time
import traceback
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sharing_probes import Side  # noqa: E402

# How long a change may take to reach both copies before a scenario fails on it. The participant's copy, in the VM, is
# brought forward each round so CloudKit fetches at once; the owner's, on the Mac in use, is too only with --take-focus,
# and otherwise waits for a push, which in Development came 7 to over 20 minutes apart.
CONVERGENCE_TIMEOUT = 900.0
POLL_INTERVAL = 2.0
# How long a copy started afresh may take before its MCP server answers.
STARTUP_TIMEOUT = 90.0


class Failure(Exception):
    """What a scenario expected and didn't find."""


class Blocked(Failure):
    """What stops every scenario after it too, such as the participant's screen locked, so the run stops there."""


def connect(name: str, endpoint: dict) -> Side:
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while True:
        try:
            return Side(name, endpoint)
        except OSError:
            if time.monotonic() > deadline:
                raise
            time.sleep(POLL_INTERVAL)


def bring_forward(command: list[str], which: str) -> None:
    """Brings a copy to the front from outside it, by `command` (`start_apps`), so CloudKit fetches there now."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise Blocked(f"bringing {which} forward timed out") from error
    if result.returncode != 0:
        raise Blocked(f"couldn't bring {which} forward: {result.stderr.strip()}")


def digest(value: str) -> str:
    """A secret value as `harness_state` gives it."""
    return "sha:" + hashlib.sha256(value.encode()).digest()[:6].hex()


class Run:
    def __init__(self, owner: Side, participant: Side, email: str, participant_forward: list[str],
                 owner_forward: list[str] | None) -> None:
        self.owner = owner
        self.participant = participant
        self.email = email
        self.participant_forward = participant_forward
        self.owner_forward = owner_forward
        self.tag = uuid.uuid4().hex[:6]
        self.steps: list[str] = []

    def note(self, text: str) -> None:
        print(f"  {text}")
        self.steps.append(text)

    def projects(self, side: Side) -> list[dict]:
        return side.call("harness_state")["projects"]

    def project(self, side: Side, name: str) -> dict | None:
        return next((project for project in self.projects(side) if project["name"] == name), None)

    def audience(self, name: str) -> dict | None:
        """Who the owner sees the project `name` shared with, as `harness_state`'s `sharedByYou` gives it."""
        return (self.project(self.owner, name) or {}).get("sharedByYou")

    def sync_until(self, description: str, check) -> object:
        """Syncs both copies, the owner first, until `check()` answers; fails past CONVERGENCE_TIMEOUT.

        Without --take-focus, only an answer shows the owner fetched: its copy holds what it held until a push reaches it,
        so a check that something never reached the owner waits first for something that did (`owner_sees`)."""
        started = time.monotonic()
        deadline = started + CONVERGENCE_TIMEOUT
        while True:
            if self.owner_forward:
                bring_forward(self.owner_forward, "this Mac's copy")
            self.owner.call("harness_sync")
            bring_forward(self.participant_forward, "the participant's copy")
            self.participant.call("harness_sync")
            answer = check()
            if answer:
                self.note(f"ok: {description} ({round(time.monotonic() - started)}s)")
                return answer
            if time.monotonic() > deadline:
                raise Failure(f"timed out: {description}")
            time.sleep(POLL_INTERVAL)

    def expect(self, condition: bool, description: str) -> None:
        if not condition:
            raise Failure(description)
        self.note(f"ok: {description}")

    def owner_secret(self, name: str) -> str:
        return f"owner-{name}-{self.tag}"

    def make_project(self, label: str) -> str:
        """A project of the owner's with a request, a saved value, and a secret only the owner has a value for."""
        name = f"E2E {label} {self.tag}"
        self.owner.call("create_project", name=name)
        self.owner.call("create_request", project=name, name="List users", http={"method": "GET", "url": "{{baseURL}}/users"})
        self.owner.call("create_variables", project=name, variables=[
            {"key": "baseURL", "value": "https://example.com/api"},
            {"key": "token", "value": self.owner_secret(name), "secret": True},
        ])
        # As Share… waits: a project shares only once it syncs.
        self.sync_until(f"{name} syncs, so it can be shared", lambda: (self.project(self.owner, name) or {}).get("shareAction") == "share")
        return name

    def share(self, name: str, permission: str | None = "readWrite", link: str | None = None) -> str:
        arguments: dict = {"project": name}
        if permission:
            arguments.update(invite=self.email, permission=permission)
        if link:
            arguments["link"] = link
        return self.owner.call("harness_share", **arguments)["url"]

    def accept(self, url: str, name: str) -> dict:
        self.participant.call("harness_accept", url=url)
        return self.sync_until(f"{name} arrives for the participant", lambda: self.project(self.participant, name))

    def shared_project(self, label: str, permission: str | None = "readWrite", link: str | None = None) -> tuple[str, dict]:
        name = self.make_project(label)
        return name, self.accept(self.share(name, permission, link), name)

    def owner_sees(self, name: str, people: int = 1, by_link: bool = False) -> None:
        """Waits until the owner's copy shows `name` shared with `people`, which it learns only by fetching."""
        audience = {"people": people, "byLink": by_link} if people or by_link else None
        whom = "no one" if not people else "1 person" if people == 1 else f"{people} people"
        self.sync_until(f"the owner sees {name} shared with {whom}" + (" and its link" if by_link else ""),
                        lambda: self.project(self.owner, name) and self.audience(name) == audience)

    def acceptances(self, name: str) -> list[str]:
        """How each person the owner's share of `name` names takes part, as the server holds it now, not as a fetch
        brought it (`probe_participants`)."""
        share = self.owner.call("probe_participants", zone=f"project-{self.project(self.owner, name)['id']}")
        return sorted(participant["acceptance"] for participant in share["participants"] if participant["role"] != "owner")

    def lost(self, name: str) -> None:
        """`name` goes from the participant's copy, which says why."""
        def gone() -> bool:
            state = self.participant.call("harness_state")
            return (all(project["name"] != name for project in state["projects"])
                    and any(name in issue and "no longer shared" in issue for issue in state["issues"]))
        self.sync_until(f"{name} goes to the participant's Trash, with a note", gone)


def variable(project: dict, key: str) -> dict:
    return next(entry for entry in project["variables"] if entry["key"] == key)


def requests(project: dict | None) -> set[str]:
    return {request["name"] for request in (project or {}).get("requests", [])}


def converged(run: Run, name: str) -> bool:
    """Both copies hold the same requests and saved values; each secret's value is each person's own."""
    mine, theirs = run.project(run.owner, name), run.project(run.participant, name)
    if not mine or not theirs:
        return False
    public = lambda project: [(entry["key"], entry["secret"], None if entry["secret"] else entry["value"]) for entry in project["variables"]]
    return mine["requests"] == theirs["requests"] and public(mine) == public(theirs)


# MARK: - Scenarios

def share_and_edit(run: Run) -> None:
    """Shared to edit: it arrives without the owner's secret value, and edits go both ways."""
    name, shared = run.shared_project("edit")
    run.expect(not shared["readOnly"] and shared["sharing"]["permission"] == "readWrite", "it arrives editable")
    run.expect(variable(shared, "token")["value"] is None, "the owner's secret value stays with the owner")
    run.owner_sees(name)
    run.participant.call("create_request", project=name, name="From the participant", http={"method": "GET", "url": "{{baseURL}}/mine"})
    run.owner.call("update_variables", project=name, variables=[{"key": "baseURL", "value": "https://example.com/v2"}])
    run.sync_until("both edits reach both copies", lambda: converged(run, name)
                   and requests(run.project(run.owner, name)) == {"List users", "From the participant"}
                   and variable(run.project(run.participant, name), "baseURL")["value"] == "https://example.com/v2")


def own_values(run: Run) -> None:
    """Each person's secret and current values stay their own; the owner's saved-value edit drops the participant's."""
    name, _ = run.shared_project("values")
    participant_secret = f"participant-{run.tag}"
    run.participant.call("harness_set_secret_values", project=name, values={"token": participant_secret})
    run.participant.call("harness_set_current_values", project=name, values={"baseURL": "https://participant.example"})
    run.participant.call("create_request", project=name, name="After my values", http={"method": "GET", "url": "{{baseURL}}/after"})
    # Their edit reaching the owner shows the owner fetched since they set their values.
    run.sync_until("the participant's edit reaches the owner", lambda: "After my values" in requests(run.project(run.owner, name)))
    mine, theirs = run.project(run.owner, name), run.project(run.participant, name)
    run.expect(variable(mine, "token")["value"] == digest(run.owner_secret(name))
               and variable(theirs, "token")["value"] == digest(participant_secret)
               and "baseURL" in theirs["currentValues"] and "baseURL" not in mine["currentValues"],
               "each person keeps their own secret and current values")
    run.owner.call("update_variables", project=name, variables=[{"key": "baseURL", "value": "https://example.com/v3"}])
    def dropped() -> bool:
        theirs = run.project(run.participant, name)
        return variable(theirs, "baseURL")["value"] == "https://example.com/v3" and "baseURL" not in theirs["currentValues"]
    run.sync_until("the owner's saved-value edit drops the participant's current value", dropped)


def view_only(run: Run) -> None:
    """Shared to view: the participant can't edit, sets only their own secret value, and can be let in to edit later."""
    name, shared = run.shared_project("view", permission="readOnly")
    run.expect(shared["readOnly"] and shared["sharing"]["permission"] == "readOnly", "it arrives to view only")
    try:
        run.participant.call("create_request", project=name, name="Refused", http={"method": "GET", "url": "{{baseURL}}/no"})
        refused = False
    except RuntimeError:
        refused = True
    run.expect(refused, "the participant's edit is refused")
    run.participant.call("harness_set_secret_values", project=name, values={"token": f"viewer-{run.tag}"})
    run.sync_until("the viewer's own secret value stays theirs", lambda:
                   variable(run.project(run.participant, name), "token")["value"] == digest(f"viewer-{run.tag}"))
    run.share(name, permission="readWrite")
    run.sync_until("letting them edit takes the lock off", lambda: not run.project(run.participant, name)["readOnly"])
    run.participant.call("create_request", project=name, name="From the editor", http={"method": "GET", "url": "{{baseURL}}/now"})
    run.sync_until("their edit reaches the owner, whose secret value stays the owner's", lambda:
                   requests(run.project(run.owner, name)) == {"List users", "From the editor"}
                   and variable(run.project(run.owner, name), "token")["value"] == digest(run.owner_secret(name)))


def by_link(run: Run) -> None:
    """Shared only by its link: anyone who opens it joins to view, until the link is turned off."""
    name = run.make_project("link")
    url = run.share(name, permission=None, link="readOnly")
    shared = run.accept(url, name)
    run.expect(shared["readOnly"], "it arrives to view only")
    run.owner_sees(name, by_link=True)
    run.share(name, permission=None, link="none")
    run.lost(name)
    run.owner_sees(name, people=0)


def lost_access(run: Run) -> None:
    """Sharing stopped, the participant removed, or the project deleted: their copy goes to the Trash; the owner's stays."""
    names = {how: run.shared_project(f"lost {how}")[0] for how in ("stop", "remove", "delete")}
    # All three at once, so the owner's waits for a push overlap.
    for name in names.values():
        run.owner_sees(name)
    run.owner.call("harness_stop_sharing", project=names["stop"])
    run.owner.call("harness_remove_participant", project=names["remove"], email=run.email)
    run.owner.call("harness_delete_project", project=names["delete"])
    for name in names.values():
        run.lost(name)
    for how in ("stop", "remove"):
        run.owner_sees(names[how], people=0)


def leave(run: Run) -> None:
    """Leaving: the participant's copy goes; the owner's stays, with them invited again, so its link brings them back."""
    name = run.make_project("leave")
    url = run.share(name)
    run.accept(url, name)
    run.owner_sees(name)
    run.participant.call("harness_delete_project", project=name)
    run.sync_until("the participant's copy goes", lambda: run.project(run.participant, name) is None)
    # CloudKit keeps someone who leaves in the share, invited again rather than removed.
    run.sync_until("the server has them invited again, and the owner's copy still shows them", lambda:
                   run.acceptances(name) == ["pending"] and run.audience(name) == {"people": 1, "byLink": False})
    issues = run.participant.call("harness_state")["issues"]
    run.expect(not any(name in issue for issue in issues), "leaving isn't reported as lost access")
    back = run.accept(url, name)
    run.expect(not back["readOnly"] and run.acceptances(name) == ["accepted"], "its link brings them back, to edit as before")


SCENARIOS = {scenario.__name__: scenario for scenario in (share_and_edit, own_values, view_only, by_link, lost_access, leave)}


def check_secrets(run: Run) -> None:
    """No secret value of one person's is ever on the other's copy."""
    theirs = {project["id"]: project for project in run.projects(run.participant)}
    for mine in run.projects(run.owner):
        other = theirs.get(mine["id"])
        if not other:
            continue
        for entry in mine.get("variables", []):
            if entry["secret"] and entry["value"]:
                match = next((candidate for candidate in other["variables"] if candidate["key"] == entry["key"]), None)
                if match and match["value"] == entry["value"]:
                    raise Failure(f"{mine['name']}: the owner's value for {entry['key']} reached the participant")
    run.note("ok: no secret value crossed")


def run_scenarios(endpoints: dict, names: list[str], take_focus: bool) -> list[dict]:
    unknown = [name for name in names if name not in SCENARIOS]
    if unknown:
        raise SystemExit(f"error: no scenario named {', '.join(unknown)}; there are {', '.join(SCENARIOS)}")
    owner = connect("owner", endpoints["owner"])
    participant = connect("participant", endpoints["participant"])
    results = []
    for name in names or list(SCENARIOS):
        print(f"{name}: {SCENARIOS[name].__doc__}")
        run = Run(owner, participant, endpoints["participant"]["email"], endpoints["participant"]["comeForward"],
                  endpoints["owner"]["comeForward"] if take_focus else None)
        started = time.monotonic()
        blocked = False
        try:
            SCENARIOS[name](run)
            check_secrets(run)
            outcome = {"scenario": name, "passed": True}
        except (Failure, RuntimeError) as error:
            print(f"  FAILED: {error}")
            blocked = isinstance(error, Blocked)
            outcome = {"scenario": name, "passed": False, "error": str(error), "trace": traceback.format_exc(),
                       "owner": owner.call("harness_state"), "participant": participant.call("harness_state")}
        outcome.update(steps=run.steps, seconds=round(time.monotonic() - started))
        results.append(outcome)
        if blocked:
            print("Stopped: the scenarios after it would stop the same way.")
            break
    return results


def main(arguments: list[str]) -> int:
    # Progress shows as it happens, piped or not.
    sys.stdout.reconfigure(line_buffering=True)
    if len(arguments) < 2 or arguments[0] not in ("reset", "run") or (arguments[0] == "run" and len(arguments) < 3):
        print(__doc__, file=sys.stderr)
        return 1
    endpoints = json.loads(Path(arguments[1]).read_text())
    if arguments[0] == "reset":
        # The participant first, so it leaves the shares before the owner's zones go.
        for name in ("participant", "owner"):
            print(f"Reset {name}: {connect(name, endpoints[name]).call('harness_reset')}")
        return 0
    if not endpoints["participant"].get("email"):
        print("error: the participant's email isn't known; run ./scripts/sharing-e2e.sh pair", file=sys.stderr)
        return 1
    names = [name for name in arguments[3:] if name != "--take-focus"]
    results = run_scenarios(endpoints, names, take_focus=len(names) < len(arguments[3:]))
    Path(arguments[2]).write_text(json.dumps(results, indent=2, sort_keys=True))
    passed = sum(result["passed"] for result in results)
    print(f"{passed} of {len(results)} scenarios passed. Wrote {arguments[2]}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
