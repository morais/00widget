from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class ConfigError(RuntimeError):
    pass


def repository_root() -> Path:
    return Path(__file__).resolve().parents[3]


def profile_path(profile: str, explicit: str | None = None) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        return path if path.is_absolute() else repository_root() / path
    candidate = Path(profile)
    if candidate.suffix in {".json", ".yaml", ".yml"} or "/" in profile:
        return candidate if candidate.is_absolute() else repository_root() / candidate
    return repository_root() / "marketing" / "app-preview" / f"{profile}.yaml"


def load_config(profile: str, explicit: str | None = None) -> tuple[dict[str, Any], Path]:
    path = profile_path(profile, explicit)
    if not path.is_file():
        raise ConfigError(f"preview config not found: {path}")
    try:
        # JSON is a strict subset of YAML. Keeping the committed .yaml file in
        # this form avoids adding PyYAML to a capture tool that otherwise uses
        # only the Python standard library plus Pillow for graphics.
        config = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ConfigError(
            f"{path} must use JSON-compatible YAML: {exc.msg} at line {exc.lineno}"
        ) from exc
    validate_config(config, path)
    return config, path


def validate_config(config: dict[str, Any], path: Path | None = None) -> None:
    label = str(path or "config")
    for key in ("device", "output", "statusBar", "stage", "scenes"):
        if key not in config:
            raise ConfigError(f"{label}: missing required key '{key}'")

    device = config["device"]
    if not isinstance(device, dict) or not str(device.get("name", "")).strip():
        raise ConfigError(f"{label}: device.name must be a non-empty string")
    for key in ("deviceType", "runtime"):
        if key in device and not str(device[key]).strip():
            raise ConfigError(f"{label}: device.{key} must be a non-empty string when set")

    output = config["output"]
    for key in ("width", "height", "fps", "duration"):
        if not isinstance(output.get(key), (int, float)) or output[key] <= 0:
            raise ConfigError(f"{label}: output.{key} must be positive")
    if output["fps"] > 30:
        raise ConfigError(f"{label}: output.fps must not exceed 30")
    if not 15 <= output["duration"] <= 30:
        raise ConfigError(f"{label}: output.duration must be between 15 and 30 seconds")

    scenes = config["scenes"]
    if not isinstance(scenes, list) or not scenes:
        raise ConfigError(f"{label}: scenes must be a non-empty array")
    supported = {"hold", "go_home", "swipe_left", "swipe_right", "open_app", "tap", "preview_phase"}
    last_start = -1.0
    duration = float(output["duration"])
    for index, scene in enumerate(scenes):
        if not isinstance(scene, dict):
            raise ConfigError(f"{label}: scenes[{index}] must be an object")
        start = scene.get("start")
        end = scene.get("end")
        action = scene.get("action", "hold")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            raise ConfigError(f"{label}: scenes[{index}] needs numeric start/end")
        if start < last_start or not 0 <= start < end <= duration:
            raise ConfigError(f"{label}: scenes[{index}] has invalid or unordered timing")
        if action not in supported:
            suffix = (
                " Lock/sleep automation is intentionally unavailable because Simulator "
                "does not expose a stable public command for it."
                if action in {"lock", "wake", "sleep_wake"}
                else ""
            )
            raise ConfigError(f"{label}: unsupported action '{action}'.{suffix}")
        if action == "tap" and not str(scene.get("target", "")).strip():
            raise ConfigError(
                f"{label}: scenes[{index}] action 'tap' needs a 'target' accessibility identifier or label"
            )
        if action == "preview_phase" and scene.get("phase") not in {"a", "b", "c"}:
            raise ConfigError(
                f"{label}: scenes[{index}] action 'preview_phase' needs phase 'a', 'b' or 'c'"
            )
        last_start = float(start)
        overlay = scene.get("overlay")
        if overlay:
            if overlay.get("style") not in {"prompt", "headline", "caption"}:
                raise ConfigError(f"{label}: scenes[{index}] has an unknown overlay style")
            if not str(overlay.get("text", "")).strip():
                raise ConfigError(f"{label}: scenes[{index}] overlay text is empty")
            overlay_start = float(overlay.get("start", start))
            overlay_end = float(overlay.get("end", end))
            if not 0 <= overlay_start < overlay_end <= duration:
                raise ConfigError(f"{label}: scenes[{index}] overlay timing is invalid")


def artifact_directory(config: dict[str, Any]) -> Path:
    value = config["output"].get("directory", "artifacts/app-preview")
    path = Path(value).expanduser()
    return path if path.is_absolute() else repository_root() / path
