from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any, Callable

from config import load_config
from overlay import render_overlay


Log = Callable[[str], None]


def render(
    raw_path: Path,
    preview_path: Path,
    config: dict[str, Any],
    temp_directory: Path,
    *,
    trim_start: float = 0.0,
    log: Log = print,
) -> list[dict[str, Any]]:
    output = config["output"]
    width = int(output["width"])
    height = int(output["height"])
    fps = float(output["fps"])
    duration = float(output["duration"])
    bitrate = str(output.get("bitrate", "11M"))
    maxrate = str(output.get("maxrate", "12M"))
    bufsize = str(output.get("bufsize", "24M"))
    overlay_width = int(output.get("overlayWidth", min(width - 80, 760)))
    overlay_y = int(output.get("overlayY", round(height * 0.17)))

    overlays: list[dict[str, Any]] = []
    for index, scene in enumerate(config["scenes"]):
        if not scene.get("overlay"):
            continue
        spec = dict(scene["overlay"])
        spec["start"] = float(spec.get("start", scene["start"]))
        spec["end"] = float(spec.get("end", scene["end"]))
        image_path = temp_directory / f"overlay-{index:02d}.png"
        dimensions = render_overlay(spec, overlay_width, image_path)
        overlays.append({**spec, **dimensions, "path": image_path})

    command = ["ffmpeg", "-hide_banner", "-y"]
    if trim_start > 0:
        command.extend(["-ss", f"{trim_start:.6f}"])
    command.extend(["-i", str(raw_path)])
    for overlay in overlays:
        command.extend(["-loop", "1", "-i", str(overlay["path"])])

    filters = [
        f"[0:v]fps={fps:g},scale={width}:{height}:force_original_aspect_ratio=increase,"
        f"crop={width}:{height}:(iw-{width})/2:(ih-{height})/2,setsar=1,"
        f"tpad=stop_mode=clone:stop_duration=1,trim=duration={duration:.3f}[base]"
    ]
    previous = "base"
    fade = float(output.get("overlayFade", 0.2))
    for index, overlay in enumerate(overlays):
        visible = float(overlay["end"]) - float(overlay["start"])
        fade_duration = min(fade, visible / 3)
        fade_out_start = max(0.0, visible - fade_duration)
        image_label = f"card{index}"
        output_label = f"v{index}"
        filters.append(
            f"[{index + 1}:v]format=rgba,"
            f"fade=t=in:st=0:d={fade_duration:.3f}:alpha=1,"
            f"fade=t=out:st={fade_out_start:.3f}:d={fade_duration:.3f}:alpha=1,"
            f"setpts=PTS-STARTPTS+{float(overlay['start']):.3f}/TB[{image_label}]"
        )
        filters.append(
            f"[{previous}][{image_label}]overlay=x=(W-w)/2:y={overlay_y}:"
            f"enable='between(t,{float(overlay['start']):.3f},{float(overlay['end']):.3f})'[{output_label}]"
        )
        previous = output_label

    preview_path.parent.mkdir(parents=True, exist_ok=True)
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            f"[{previous}]",
            "-t",
            f"{duration:.3f}",
            "-r",
            f"{fps:g}",
            "-fps_mode",
            "cfr",
            "-an",
            "-c:v",
            "libx264",
            "-profile:v",
            "high",
            "-level:v",
            "4.1",
            "-pix_fmt",
            "yuv420p",
            "-b:v",
            bitrate,
            "-maxrate",
            maxrate,
            "-bufsize",
            bufsize,
            "-movflags",
            "+faststart",
            "-map_metadata",
            "-1",
            str(preview_path),
        ]
    )
    log("Rendering overlays and App Store output")
    subprocess.run(command, check=True)
    return [
        {
            "text": overlay["text"],
            "style": overlay["style"],
            "start": overlay["start"],
            "end": overlay["end"],
            "lines": overlay["lines"],
        }
        for overlay in overlays
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Render an App Store Preview from a raw Simulator movie")
    parser.add_argument("profile", nargs="?", default="ios-main")
    parser.add_argument("--config")
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--temp", type=Path, required=True)
    parser.add_argument("--trim-start", type=float, default=0.0)
    args = parser.parse_args()
    config, _ = load_config(args.profile, args.config)
    overlays = render(args.raw, args.output, config, args.temp, trim_start=args.trim_start)
    print(json.dumps({"overlays": overlays}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
