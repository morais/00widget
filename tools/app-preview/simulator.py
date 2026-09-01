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
            f"no available Simulator named '{name}'{qualifier}; run 'xcrun simctl list devices available'"
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
    appearance = str(config.get("appearance", "light"))
    if appearance not in {"light", "dark"}:
        raise SimulatorError("device.appearance must be 'light' or 'dark'")
    run(["xcrun", "simctl", "ui", udid, "appearance", appearance])

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
