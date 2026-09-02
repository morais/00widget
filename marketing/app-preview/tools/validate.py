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
        "-show_entries",
        "stream=codec_name,codec_type,profile,level,width,height,avg_frame_rate,field_order,"
        "sample_rate,channels,channel_layout,bit_rate:format=duration,size",
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
    video = next((stream for stream in payload["streams"] if stream.get("codec_type") == "video"), None)
    audio = next((stream for stream in payload["streams"] if stream.get("codec_type") == "audio"), None)
    if video is None:
        raise ValidationError("App Store preview validation failed: no video track")
    container = payload["format"]
    duration = float(container["duration"])
    fps = float(Fraction(video["avg_frame_rate"]))
    size_bytes = int(container["size"])
    audio_bit_rate = int(audio.get("bit_rate", 0)) if audio else 0
    expected = config["output"]

    checks = [
        (15 <= duration <= 30, "duration", f"{duration:.2f} s", "must be between 15 and 30 seconds"),
        (
            video["width"] == int(expected["width"]) and video["height"] == int(expected["height"]),
            "resolution",
            f"{video['width']}x{video['height']}",
            f"must be {expected['width']}x{expected['height']}",
        ),
        (fps <= 30.001, "frame rate", f"{fps:g} fps", "must not exceed 30 fps"),
        (video["codec_name"] == "h264", "codec", video["codec_name"], "must be h264"),
        (
            video.get("profile") == "High" and int(video.get("level", 999)) <= 40,
            "video profile",
            f"{video.get('profile', 'unknown')} Level {int(video.get('level', 0)) / 10:g}",
            "must be H.264 High Profile Level 4.0 or lower",
        ),
        (
            video.get("field_order") == "progressive",
            "scan",
            video.get("field_order", "unknown"),
            "must be progressive",
        ),
        (audio is not None, "audio track", "present" if audio else "missing", "must be present and enabled"),
        (
            audio is not None and audio.get("codec_name") == "aac" and audio.get("profile") == "LC",
            "audio codec",
            f"{audio.get('codec_name', 'missing')} {audio.get('profile', '')}" if audio else "missing",
            "must be AAC-LC",
        ),
        (
            audio is not None and audio.get("channels") == 2 and audio.get("channel_layout") == "stereo",
            "audio channels",
            f"{audio.get('channels', 0)} ({audio.get('channel_layout', 'unknown')})" if audio else "missing",
            "must be two-channel stereo",
        ),
        (
            audio is not None and audio.get("sample_rate") in {"44100", "48000"},
            "audio sample rate",
            f"{audio.get('sample_rate', 'missing')} Hz" if audio else "missing",
            "must be 44.1 kHz or 48 kHz",
        ),
        (
            230_400 <= audio_bit_rate <= 281_600,
            "audio bit rate",
            f"{audio_bit_rate / 1000:.0f} kbps",
            "must target 256 kbps AAC",
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
        "width": video["width"],
        "height": video["height"],
        "fps": fps,
        "codec": video["codec_name"],
        "profile": video.get("profile"),
        "level": video.get("level"),
        "fieldOrder": video.get("field_order"),
        "audioCodec": audio.get("codec_name") if audio else None,
        "audioProfile": audio.get("profile") if audio else None,
        "audioSampleRate": int(audio["sample_rate"]) if audio else None,
        "audioChannels": audio.get("channels") if audio else None,
        "audioBitRate": audio_bit_rate if audio else None,
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
