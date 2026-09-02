from __future__ import annotations

import argparse
import json
import subprocess
from fractions import Fraction
from pathlib import Path
from typing import Any

from config import load_config


class ValidationError(RuntimeError):
    pass


def probe(path: Path) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,width,height,avg_frame_rate,field_order:format=duration,size",
        "-of",
        "json",
        str(path),
    ]
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE)
    return json.loads(result.stdout)


def validate(path: Path, config: dict[str, Any], *, emit: bool = True) -> dict[str, Any]:
    if not path.is_file():
        raise ValidationError(f"preview file not found: {path}")
    payload = probe(path)
    stream = payload["streams"][0]
    container = payload["format"]
    duration = float(container["duration"])
    fps = float(Fraction(stream["avg_frame_rate"]))
    size_bytes = int(container["size"])
    expected = config["output"]

    checks = [
        (15 <= duration <= 30, "duration", f"{duration:.2f} s", "must be between 15 and 30 seconds"),
        (
            stream["width"] == int(expected["width"]) and stream["height"] == int(expected["height"]),
            "resolution",
            f"{stream['width']}x{stream['height']}",
            f"must be {expected['width']}x{expected['height']}",
        ),
        (fps <= 30.001, "frame rate", f"{fps:g} fps", "must not exceed 30 fps"),
        (stream["codec_name"] == "h264", "codec", stream["codec_name"], "must be h264"),
        (
            stream.get("field_order") == "progressive",
            "scan",
            stream.get("field_order", "unknown"),
            "must be progressive",
        ),
        (size_bytes < 500_000_000, "size", f"{size_bytes / 1_000_000:.1f} MB", "must be under 500 MB"),
    ]
    failures = []
    rendered_checks = []
    for passed, name, value, requirement in checks:
        rendered_checks.append({"name": name, "passed": passed, "value": value, "requirement": requirement})
        if emit:
            print(f"{'✓' if passed else '✗'} {name}: {value}")
        if not passed:
            failures.append(f"{name} {requirement} (got {value})")
    report = {
        "passed": not failures,
        "path": str(path),
        "duration": duration,
        "width": stream["width"],
        "height": stream["height"],
        "fps": fps,
        "codec": stream["codec_name"],
        "fieldOrder": stream.get("field_order"),
        "sizeBytes": size_bytes,
        "checks": rendered_checks,
    }
    if failures:
        raise ValidationError("App Store preview validation failed: " + "; ".join(failures))
    if emit:
        print("App Store preview validation passed.")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an App Store Preview video")
    parser.add_argument("profile", nargs="?", default="ios-main")
    parser.add_argument("video", type=Path)
    parser.add_argument("--config")
    args = parser.parse_args()
    config, _ = load_config(args.profile, args.config)
    try:
        validate(args.video, config)
    except (ValidationError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
