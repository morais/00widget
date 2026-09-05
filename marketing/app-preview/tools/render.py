from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any, Callable

from config import load_config
from overlay import render_overlay


Log = Callable[[str], None]


def scene_hits(raw_path: Path, threshold: float) -> list[float]:
    """First frame times of every scene change above `threshold`, merged."""
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(raw_path),
            "-vf",
            f"select='gt(scene,{threshold})',showinfo",
            "-an",
            "-f",
            "null",
            "-",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    candidates = [
        float(match.group(1))
        for match in re.finditer(r"pts_time:([0-9]+(?:\.[0-9]+)?)", result.stderr)
    ]
    hits: list[float] = []
    for candidate in candidates:
        if not hits or candidate - hits[-1] >= 1.0:
            hits.append(candidate)
    return hits


def detect_page_transitions(raw_path: Path, expected: int) -> list[float]:
    """Return the first frame of each visually distinct page swipe.

    CoreSimulator's recorder can collapse a static interval instead of giving
    the preceding frame its full wall-clock duration. The UI test still fires
    on time, but the following swipe then appears early in the movie. Detecting
    the large scene changes lets normalization restore those configured holds
    without modifying the raw diagnostic capture.
    """
    if expected == 0:
        return []
    transitions = scene_hits(raw_path, 0.08)
    return transitions if len(transitions) == expected else []


def render(
    raw_path: Path,
    preview_path: Path,
    config: dict[str, Any],
    temp_directory: Path,
    *,
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
    overlay_height_scale = float(output.get("overlayHeightScale", 1))

    overlays: list[dict[str, Any]] = []
    for index, scene in enumerate(config["scenes"]):
        if not scene.get("overlay"):
            continue
        spec = dict(scene["overlay"])
        spec["start"] = float(spec.get("start", scene["start"]))
        spec["end"] = float(spec.get("end", scene["end"]))
        spec.setdefault("heightScale", overlay_height_scale)
        image_path = temp_directory / f"overlay-{index:02d}.png"
        dimensions = render_overlay(spec, overlay_width, image_path)
        overlays.append({**spec, **dimensions, "path": image_path})

    temp_directory.mkdir(parents=True, exist_ok=True)
    normalized_path = temp_directory / "normalized.mp4"
    action_starts = [
        float(scene["start"])
        for scene in config["scenes"]
        if scene.get("action") != "hold"
    ]
    raw_transitions = detect_page_transitions(raw_path, len(action_starts))
    normalize_command = ["ffmpeg", "-hide_banner", "-y"]
    normalize_command.extend(["-i", str(raw_path)])
    if raw_transitions:
        log(
            "Aligning Simulator page transitions to "
            + ", ".join(f"{value:.1f}s" for value in action_starts)
        )
        raw_boundaries = [0.0, *raw_transitions]
        desired_boundaries = [0.0, *action_starts, duration]
        segments: list[str] = []
        segment_filters: list[str] = []
        for index, raw_start in enumerate(raw_boundaries):
            desired_length = desired_boundaries[index + 1] - desired_boundaries[index]
            raw_end = raw_transitions[index] if index < len(raw_transitions) else None
            trim = f"trim=start={raw_start:.6f}"
            if raw_end is not None:
                trim += f":end={raw_end:.6f}"
            label = f"timeline{index}"
            segment_filters.append(
                f"[0:v]{trim},setpts=PTS-STARTPTS,fps={fps:g},"
                f"tpad=stop_mode=clone:stop_duration={desired_length:.3f},"
                f"trim=duration={desired_length:.3f}[{label}]"
            )
            segments.append(label)
        joined = "".join(f"[{label}]" for label in segments)
        segment_filters.append(
            f"{joined}concat=n={len(segments)}:v=1:a=0,"
            f"scale={width}:{height}:force_original_aspect_ratio=increase,"
            f"crop={width}:{height}:(iw-{width})/2:(ih-{height})/2,setsar=1[normalized]"
        )
        normalize_command.extend(
            ["-filter_complex", ";".join(segment_filters), "-map", "[normalized]"]
        )
    else:
        if action_starts:
            log("Could not identify every page transition; preserving Simulator timestamps")
        normalize_command.extend(
            [
                "-vf",
                f"fps={fps:g},scale={width}:{height}:force_original_aspect_ratio=increase,"
                f"crop={width}:{height}:(iw-{width})/2:(ih-{height})/2,setsar=1,"
                f"tpad=stop_mode=clone:stop_duration={duration:.3f},"
                f"trim=duration={duration:.3f}",
            ]
        )
    normalize_command.extend(
        [
            "-r",
            f"{fps:g}",
            "-fps_mode",
            "cfr",
            "-t",
            f"{duration:.3f}",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-crf",
            "0",
            "-pix_fmt",
            "yuv420p",
            str(normalized_path),
        ]
    )
    log("Normalizing Simulator frame timing")
    subprocess.run(normalize_command, check=True)

    command = ["ffmpeg", "-hide_banner", "-y", "-i", str(normalized_path)]
    for overlay in overlays:
        command.extend(["-loop", "1", "-i", str(overlay["path"])])
    audio_input = len(overlays) + 1
    # App Store Connect requires an enabled stereo AAC track. Very low-level
    # dither is inaudible but keeps AAC's encoded bitrate near the required
    # 256 kbps; digital silence otherwise collapses to only a few kbps.
    command.extend(
        [
            "-f",
            "lavfi",
            "-i",
            "anoisesrc=color=white:amplitude=0.00003:sample_rate=48000",
        ]
    )

    filters = ["[0:v]setpts=PTS-STARTPTS[base]"]
    fade = float(output.get("overlayFade", 0.2))
    prompt_segments: list[str] = []
    cursor = 0.0
    for index, overlay in enumerate(overlays):
        start = float(overlay["start"])
        end = float(overlay["end"])
        if start > cursor:
            gap_label = f"gap{index}"
            filters.append(
                f"color=c=black@0.0:s={width}x{height}:r={fps:g}:"
                f"d={start - cursor:.3f},format=rgba[{gap_label}]"
            )
            prompt_segments.append(gap_label)

        visible = end - start
        fade_duration = min(fade, visible / 3)
        fade_out_start = max(0.0, visible - fade_duration)
        image_label = f"card{index}"
        canvas_label = f"cardcanvas{index}"
        segment_label = f"prompt{index}"
        card_y = overlay_y - (int(overlay["height"]) - int(overlay["baseHeight"]))
        # Build each prompt as its own zero-based clip. Applying alpha fade-out
        # before fade-in matters: FFmpeg otherwise latches the initially
        # transparent alpha and can hide the card for its entire scene.
        filters.append(
            f"[{index + 1}:v]format=rgba,"
            f"fade=t=out:st={fade_out_start:.3f}:d={fade_duration:.3f}:alpha=1,"
            f"fade=t=in:st=0:d={fade_duration:.3f}:alpha=1,"
            f"trim=duration={visible:.3f},setpts=PTS-STARTPTS[{image_label}]"
        )
        filters.append(
            f"color=c=black@0.0:s={width}x{height}:r={fps:g}:"
            f"d={visible:.3f},format=rgba[{canvas_label}]"
        )
        filters.append(
            f"[{canvas_label}][{image_label}]overlay=x=(W-w)/2:y={card_y}:"
            f"shortest=1[{segment_label}]"
        )
        prompt_segments.append(segment_label)
        cursor = end

    if overlays:
        if cursor < duration:
            filters.append(
                f"color=c=black@0.0:s={width}x{height}:r={fps:g}:"
                f"d={duration - cursor:.3f},format=rgba[prompttail]"
            )
            prompt_segments.append("prompttail")
        segment_inputs = "".join(f"[{label}]" for label in prompt_segments)
        filters.append(
            f"{segment_inputs}concat=n={len(prompt_segments)}:v=1:a=0,"
            "format=rgba[prompttrack]"
        )
        # The normalized base contains physical frames through Simulator's
        # startup timestamp gaps, so a single final composition keeps every
        # prompt aligned with its configured scene.
        filters.append("[base][prompttrack]overlay=eof_action=pass[output]")
        output_label = "output"
    else:
        output_label = "base"

    preview_path.parent.mkdir(parents=True, exist_ok=True)
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            f"[{output_label}]",
            "-map",
            f"{audio_input}:a:0",
            "-t",
            f"{duration:.3f}",
            "-r",
            f"{fps:g}",
            "-fps_mode",
            "cfr",
            "-c:v",
            "libx264",
            "-profile:v",
            "high",
            "-level:v",
            "4.0",
            "-pix_fmt",
            "yuv420p",
            "-b:v",
            bitrate,
            "-maxrate",
            maxrate,
            "-bufsize",
            bufsize,
            "-c:a",
            "aac",
            "-profile:a",
            "aac_low",
            "-b:a",
            "256k",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-disposition:a:0",
            "default",
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
    args = parser.parse_args()
    config, _ = load_config(args.profile, args.config)
    overlays = render(args.raw, args.output, config, args.temp)
    print(json.dumps({"overlays": overlays}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
