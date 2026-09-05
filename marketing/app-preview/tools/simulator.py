from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Any, Callable


class SimulatorError(RuntimeError):
    pass


Log = Callable[[str], None]


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SimulatorError(f"required command is unavailable: {name}")
    return path


def run(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def resolve_device(name: str, runtime: str | None = None) -> tuple[str, str]:
    require_tool("xcrun")
    result = run(["xcrun", "simctl", "list", "devices", "available", "-j"], capture=True)
    payload = json.loads(result.stdout)
    matches: list[tuple[str, str, dict[str, Any]]] = []
    for runtime_id, devices in payload.get("devices", {}).items():
        if runtime and runtime not in runtime_id:
            continue
        for device in devices:
            if device.get("name") == name and device.get("isAvailable", True):
                matches.append((runtime_id, device["udid"], device))
    if not matches:
        qualifier = f" in runtime matching '{runtime}'" if runtime else ""
        raise SimulatorError(
            f"no available Simulator named '{name}'{qualifier}; "
            "create it deliberately with "
            "'./marketing/app-preview/run.sh ios-main --create-device'"
        )
    if len(matches) > 1:
        choices = ", ".join(f"{runtime_id} ({udid})" for runtime_id, udid, _ in matches)
        raise SimulatorError(
            f"more than one available Simulator is named '{name}': {choices}. "
            "Set device.runtime in the preview config."
        )
    runtime_id, udid, _ = matches[0]
    return udid, runtime_id


def boot(udid: str, log: Log) -> None:
    result = run(["xcrun", "simctl", "boot", udid], check=False, capture=True)
    if result.returncode and "current state: Booted" not in result.stderr:
        raise SimulatorError(result.stderr.strip() or f"could not boot Simulator {udid}")
    log("Simulator boot requested")
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    # -CurrentDeviceUDID is Simulator.app's supported device-selection argument.
    run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])


def configure_visual_state(udid: str, config: dict[str, Any]) -> None:
    set_appearance(udid, str(config.get("appearance", "light")))

    status = config.get("statusBar", {})
    supported = {
        "time": "--time",
        "batteryLevel": "--batteryLevel",
        "batteryState": "--batteryState",
        "wifiBars": "--wifiBars",
        "cellularBars": "--cellularBars",
        "operatorName": "--operatorName",
    }
    args = ["xcrun", "simctl", "status_bar", udid, "override"]
    for key, flag in supported.items():
        if key in status:
            args.extend([flag, str(status[key])])
    run(args)


def set_appearance(udid: str, appearance: str) -> None:
    if appearance not in {"light", "dark"}:
        raise SimulatorError("device.appearance must be 'light' or 'dark'")
    run(["xcrun", "simctl", "ui", udid, "appearance", appearance])


def clear_status_bar(udid: str) -> None:
    run(["xcrun", "simctl", "status_bar", udid, "clear"], check=False, capture=True)


def app_container(udid: str, bundle_id: str) -> Path | None:
    result = run(
        ["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"],
        check=False,
        capture=True,
    )
    if result.returncode:
        return None
    path = Path(result.stdout.strip())
    return path if path.is_dir() else None


def find_devices_by_name(name: str) -> list[tuple[str, str, dict[str, Any]]]:
    """Every simulator called `name`, in any state or runtime."""
    require_tool("xcrun")
    result = run(["xcrun", "simctl", "list", "devices", "-j"], capture=True)
    payload = json.loads(result.stdout)
    found = []
    for runtime_id, devices in payload.get("devices", {}).items():
        for device in devices:
            if device.get("name") == name:
                found.append((runtime_id, device["udid"], device))
    return found


def resolve_runtime(fragment: str) -> dict[str, Any]:
    """One available runtime matching `fragment`, or a clear refusal."""
    require_tool("xcrun")
    result = run(["xcrun", "simctl", "list", "runtimes", "available", "-j"], capture=True)
    runtimes = json.loads(result.stdout).get("runtimes", [])
    matches = [runtime for runtime in runtimes if fragment in runtime.get("identifier", "")]
    if not matches:
        raise SimulatorError(
            f"no available Simulator runtime matches '{fragment}'; "
            "run 'xcrun simctl list runtimes available'"
        )
    if len(matches) > 1:
        choices = ", ".join(runtime["identifier"] for runtime in matches)
        raise SimulatorError(
            f"more than one available runtime matches '{fragment}': {choices}. "
            "Narrow device.runtime in the preview config."
        )
    return matches[0]


def resolve_device_type(name_or_identifier: str) -> dict[str, Any]:
    """One device type by human name or identifier, or a clear refusal."""
    require_tool("xcrun")
    result = run(["xcrun", "simctl", "list", "devicetypes", "-j"], capture=True)
    device_types = json.loads(result.stdout).get("devicetypes", [])
    matches = [
        device_type
        for device_type in device_types
        if name_or_identifier in (device_type.get("name"), device_type.get("identifier"))
    ]
    if not matches:
        raise SimulatorError(
            f"unknown Simulator device type '{name_or_identifier}'; "
            "run 'xcrun simctl list devicetypes'"
        )
    return matches[0]


def create_device(
    name: str,
    device_type: str | None,
    runtime_fragment: str | None,
    appearance: str,
    replace: bool,
    log: Log,
) -> dict[str, str]:
    """Create the named marketing Simulator from the preview config.

    Deliberate by construction: it refuses when a device with the same name
    already exists unless `replace` is passed, and the normal capture path
    never calls it — a capture that silently recreated the stage would wipe
    the hand-placed widgets it films.
    """
    if not (device_type or "").strip():
        raise SimulatorError(
            "device.deviceType is required to create a Simulator "
            "(e.g. 'iPhone 17 Pro'); refusing to guess the marketing model"
        )
    if not (runtime_fragment or "").strip():
        raise SimulatorError(
            "device.runtime is required to create a Simulator "
            "(e.g. 'iOS-26-5'); refusing to guess the marketing runtime"
        )
    existing = find_devices_by_name(name)
    if existing and not replace:
        choices = ", ".join(f"{runtime_id} ({udid})" for runtime_id, udid, _ in existing)
        raise SimulatorError(
            f"a Simulator named '{name}' already exists: {choices}. "
            "Pass --replace to shut it down, delete it, and create it again."
        )
    for runtime_id, udid, device in existing:
        log(f"Deleting existing {name} ({runtime_id}, {udid})")
        run(["xcrun", "simctl", "shutdown", udid], check=False, capture=True)
        run(["xcrun", "simctl", "delete", udid])

    resolved_type = resolve_device_type(device_type.strip())
    runtime = resolve_runtime(runtime_fragment.strip())
    supported = {
        entry.get("identifier")
        for entry in runtime.get("supportedDeviceTypes", [])
    }
    if supported and resolved_type["identifier"] not in supported:
        raise SimulatorError(
            f"{resolved_type['name']} is not supported by {runtime['identifier']}"
        )
    log(f"Creating {name} ({resolved_type['name']}, {runtime['identifier']})")
    created = run(
        ["xcrun", "simctl", "create", name, resolved_type["identifier"], runtime["identifier"]],
        capture=True,
    )
    udid = created.stdout.strip()
    if not udid:
        raise SimulatorError(f"'simctl create' reported success but printed no UDID for '{name}'")
    return {"udid": udid, "runtime": runtime["identifier"], "deviceType": resolved_type["name"]}
